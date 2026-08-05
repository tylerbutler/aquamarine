//// The socket: one WebSocket connection, many topics.
////
//// A socket is an OTP actor that owns the WebSocket transport. Every inbound
//// frame arrives in its mailbox, is decoded through the configured
//// [`Codec`](aquamarine/codec.html#Codec), and is routed onward — to a caller
//// blocked on a specific ref, or to the channel joined to that frame's topic.
//// The calling process never touches the socket.
////
//// ## One socket, many channels
////
//// Phoenix multiplexes many topics over a single connection, and so does
//// this. Open a socket once, [`channel.join`](aquamarine/channel.html#join)
//// as many topics as you need, and they share one connection and one
//// heartbeat. The socket keeps a routing table keyed by topic; a frame is
//// delivered to the channel that owns its topic and to nobody else.
////
//// The socket does **not** close itself when the last channel leaves. A
//// transient zero-channel window is a normal thing to pass through, not a
//// reason to drop the connection. Closing is [`close`](#close), explicitly.
////
//// ## Why an actor
////
//// A single blocking `receive` has nowhere to put a frame it is not currently
//// interested in, so waiting for a specific reply meant discarding everything
//// else. Here, a frame that nobody is blocked on goes to its topic's subject
//// and sits in that mailbox until the caller gets to it.
////
//// ## Supervision
////
//// [`supervised`](#supervised) returns a child specification for an OTP
//// supervision tree, so a socket can live in your application's supervisor
//// rather than be babysat by whatever process happened to open it. Supervised
//// sockets are named, because a restarted socket is a different process and a
//// name is the only handle that survives that.
////
//// **A restart does not rejoin.** The restarted socket comes back with an
//// empty routing table and no joined topics, and every `Channel` handle from
//// before the restart is stale: its events subject belonged to the dead actor
//// and will never receive again. Re-join after a restart. Automatic rejoin is
//// a property of in-actor reconnect, not of supervisor restart, and this
//// module does not provide it.
////
//// ## Process ownership
////
//// The actor owns everything with state: the transport, the inbound sink, the
//// ref counter, the heartbeat timer, and the routing table. Each channel's
//// events subject is owned by whoever created it — normally the process that
//// called `channel.join` — and only that process may receive from it.
//// Everything in this module is safe to call from any process.

import aquamarine/codec.{type Codec, type Incoming}
import aquamarine/error.{type AquamarineError}
import aquamarine/transport.{type Connector, type Transport}
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import logging

/// Default heartbeat interval, matching the Phoenix JS client.
pub const default_heartbeat_ms: Int = 30_000

/// How long the actor's initialiser — which runs the connector — may take.
const init_timeout_ms: Int = 30_000

/// How long [`close`](#close) and [`leave`](#leave) wait for the actor to
/// answer.
const call_timeout_ms: Int = 5000

/// What a channel's events subject carries.
///
/// Errors travel in-band because they are ordinary channel events from the
/// caller's point of view: the server closed the channel, a frame would not
/// decode, the socket went away.
pub type Event =
  Result(Incoming, AquamarineError)

/// Handle to a running socket actor.
pub opaque type Socket {
  Socket(subject: Subject(Message))
}

/// A successful join: the ref the join was sent under, and the reply the
/// server accepted it with.
pub type Joined {
  Joined(join_ref: String, reply: Incoming)
}

pub opaque type Message {
  /// An inbound frame, pushed here by the transport.
  Inbound(transport.Frame)
  /// Join a topic. The actor mints the join ref, encodes the frame, sends it,
  /// routes the matching reply to `reply_to`, and — on acceptance — registers
  /// `events` as the destination for that topic's frames.
  Join(
    topic: String,
    payload: json.Json,
    events: Subject(Event),
    reply_to: Subject(Result(Joined, AquamarineError)),
  )
  /// Leave a topic: send the leave frame and drop the routing entry.
  Leave(
    topic: String,
    join_ref: String,
    reply_to: Subject(Result(Nil, AquamarineError)),
  )
  /// Fire-and-forget push. The actor mints the ref.
  Push(join_ref: String, topic: String, event: String, payload: json.Json)
  /// Push whose reply is routed back to `reply_to` instead of to the topic's
  /// channel. The actor registers the ref before sending it.
  PushAwaitingReply(
    join_ref: String,
    topic: String,
    event: String,
    payload: json.Json,
    reply_to: Subject(Event),
  )
  /// Give up on a pending reply, so the table cannot grow without bound.
  ///
  /// Cancellation is by reply subject rather than by ref: the actor mints the
  /// ref, so a caller that times out never learned it. Two variants because
  /// joins and pushes reply on differently-typed subjects.
  CancelPush(reply_to: Subject(Event))
  CancelJoin(reply_to: Subject(Result(Joined, AquamarineError)))
  /// Emit one heartbeat frame. The actor mints the ref.
  Heartbeat
  Close(reply_to: Subject(Result(Nil, AquamarineError)))
}

/// A caller blocked on the reply to a specific outbound ref.
///
/// Joins and pushes want different things from the same mechanism: a join
/// wants a verdict (`JoinRejected` is an error), while a push reply carrying a
/// non-ok status is a perfectly ordinary reply that the caller should see.
type Waiter {
  JoinWaiter(
    topic: String,
    events: Subject(Event),
    reply_to: Subject(Result(Joined, AquamarineError)),
  )
  ReplyWaiter(reply_to: Subject(Event))
}

type State {
  State(
    self: Subject(Message),
    transport: Transport,
    codec: Codec,
    /// Where each topic's frames go. Inbound frames route by
    /// `incoming.topic`; a frame for a topic nobody joined is dropped.
    routes: Dict(String, Subject(Event)),
    /// Callers blocked on a reply, keyed by the ref their frame went out
    /// under. This table is the thing a single blocking `receive` could not
    /// express: with it, a frame nobody asked for still has somewhere to go.
    pending: Dict(String, Waiter),
    /// How often to emit a heartbeat, and the timer for the next one. The
    /// heartbeat is a self-message on a timer rather than a second actor —
    /// once the socket owns both the counter and the transport, that is all it
    /// ever needed to be.
    ///
    /// It runs for the life of the socket regardless of how many channels are
    /// joined, matching the Phoenix JS client: the heartbeat lives on the
    /// socket, not the channel.
    heartbeat_ms: Int,
    heartbeat_timer: Option(process.Timer),
    /// Next ref to mint. Refs are minted inside the actor, in the same handler
    /// that sends the frame carrying them, so ref order and send order cannot
    /// diverge.
    next_ref: Int,
    /// True once the socket is known to be gone. The actor deliberately stays
    /// alive in this state so that a caller who was mid-flight gets
    /// `ChannelClosed` back rather than having its message vanish into a dead
    /// mailbox — sends to a dead process succeed silently in OTP.
    gone: Bool,
  )
}

/// Open a WebSocket to a compatible server.
///
/// The connection carries no topics until something joins one. The codec
/// belongs to the socket, not to a channel: the socket has to decode every
/// frame to read its topic before it can route, so one socket serves one wire
/// protocol — matching Phoenix's one-serializer-per-socket model.
pub fn connect(
  host host: String,
  port port: Int,
  path path: String,
  codec codec: Codec,
) -> Result(Socket, AquamarineError) {
  start(
    transport.gluegun_connector(host:, port:, path:),
    codec,
    default_heartbeat_ms,
  )
}

/// Like [`connect`](#connect) but takes a `Connector` and an explicit
/// heartbeat interval, so tests can plug in an in-memory transport and a short
/// heartbeat.
@internal
pub fn start(
  connector: Connector,
  codec: Codec,
  heartbeat_ms: Int,
) -> Result(Socket, AquamarineError) {
  start_named(connector, codec, heartbeat_ms, None)
}

/// Start a socket, optionally registering it under a name.
@internal
pub fn start_named(
  connector: Connector,
  codec: Codec,
  heartbeat_ms: Int,
  name: Option(Name),
) -> Result(Socket, AquamarineError) {
  // The connector runs inside the actor's initialiser, where the only failure
  // channel is a `String`. Route the typed error out of band.
  let failure = process.new_subject()

  case
    actor.start(build_with_failure(
      connector,
      codec,
      heartbeat_ms,
      name,
      failure,
    ))
  {
    Ok(started) -> Ok(Socket(subject: started.data))
    Error(_) ->
      case process.receive(failure, 0) {
        Ok(err) -> Error(err)
        Error(Nil) -> Error(error.InternalError("failed to start socket actor"))
      }
  }
}

/// Build the actor for supervision, where a connect failure has nowhere typed
/// to go and simply fails the child start.
fn build(
  connector: Connector,
  codec: Codec,
  heartbeat_ms: Int,
  name: Option(Name),
) -> actor.Builder(State, Message, Subject(Message)) {
  build_with_failure(
    connector,
    codec,
    heartbeat_ms,
    name,
    process.new_subject(),
  )
}

fn build_with_failure(
  connector: Connector,
  codec: Codec,
  heartbeat_ms: Int,
  name: Option(Name),
  failure: Subject(AquamarineError),
) -> actor.Builder(State, Message, Subject(Message)) {
  let builder =
    actor.new_with_initialiser(init_timeout_ms, fn(self) {
      let sink = process.new_subject()
      case connector(sink) {
        Error(err) -> {
          process.send(failure, err)
          Error("connector failed")
        }
        Ok(tx) -> {
          let selector =
            process.new_selector()
            |> process.select(self)
            |> process.select_map(sink, Inbound)

          actor.initialised(State(
            self: self,
            transport: tx,
            codec: codec,
            routes: dict.new(),
            pending: dict.new(),
            heartbeat_ms: heartbeat_ms,
            heartbeat_timer: Some(process.send_after(
              self,
              heartbeat_ms,
              Heartbeat,
            )),
            next_ref: 1,
            gone: False,
          ))
          |> actor.selecting(selector)
          |> actor.returning(self)
          |> Ok
        }
      }
    })
    |> actor.on_message(handle)

  case name {
    Some(Name(name)) -> actor.named(builder, name)
    None -> builder
  }
}

/// A registered name for a socket.
///
/// Names let a process reach a socket without the handle being threaded
/// through its own state, and they are what makes a supervised socket
/// reachable at all — a restarted socket is a different process, and the name
/// is the only thing that survives.
pub opaque type Name {
  Name(name: process.Name(Message))
}

/// Generate a fresh name. The prefix is for readability in crash reports; a
/// unique suffix is appended, so two calls never collide.
pub fn new_name(prefix prefix: String) -> Name {
  Name(process.new_name(prefix))
}

/// A handle to whichever socket currently holds `name`.
///
/// Safe to build before the socket exists and safe to keep across a restart —
/// it resolves at send time. Sends to a name nobody holds are silently
/// dropped, as OTP sends always are.
pub fn named(name: Name) -> Socket {
  Socket(subject: process.named_subject(name.name))
}

/// The process currently holding this socket, if any.
@internal
pub fn owner(socket: Socket) -> Result(process.Pid, Nil) {
  process.subject_owner(socket.subject)
}

/// A child specification for an OTP supervision tree.
///
/// The socket is `Transient`: it is restarted if it dies abnormally, but a
/// deliberate [`close`](#close) exits normally and is not second-guessed by
/// the supervisor.
///
/// Losing the *connection* does not exit the actor — it stays up so that
/// callers get `ChannelClosed` instead of silence — so a dropped connection is
/// not something a supervisor restart recovers from. Reconnect is the actor's
/// own business.
///
/// The restarted socket has **no joined channels**, and `Channel` handles from
/// before the restart are stale. See the module documentation.
pub fn supervised(
  host host: String,
  port port: Int,
  path path: String,
  codec codec: Codec,
  name name: Name,
) -> supervision.ChildSpecification(Socket) {
  supervised_with(
    transport.gluegun_connector(host:, port:, path:),
    codec,
    default_heartbeat_ms,
    name,
  )
}

/// Like [`supervised`](#supervised) but takes a `Connector` and an explicit
/// heartbeat interval.
@internal
pub fn supervised_with(
  connector: Connector,
  codec: Codec,
  heartbeat_ms: Int,
  name: Name,
) -> supervision.ChildSpecification(Socket) {
  supervision.worker(fn() {
    build(connector, codec, heartbeat_ms, Some(name))
    |> actor.start
    |> result.map(fn(started: actor.Started(Subject(Message))) {
      actor.Started(pid: started.pid, data: Socket(subject: started.data))
    })
  })
  |> supervision.restart(supervision.Transient)
}

/// Join a topic and block until the server replies.
///
/// On acceptance, `events` becomes the destination for that topic's inbound
/// frames. Frames for other topics that arrive in the meantime still reach
/// their own channels — they are not dropped.
///
/// Returns `Error(AlreadyJoined(topic))` if the topic is already joined:
/// silently replacing the routing entry would orphan the first channel's
/// subject with no error raised anywhere.
pub fn join(
  socket: Socket,
  topic: String,
  payload: json.Json,
  events: Subject(Event),
  timeout: Int,
) -> Result(Joined, AquamarineError) {
  let reply_to = process.new_subject()
  process.send(socket.subject, Join(topic, payload, events, reply_to))

  case process.receive(reply_to, timeout) {
    Ok(result) -> result
    Error(Nil) -> {
      process.send(socket.subject, CancelJoin(reply_to))
      Error(error.ReplyTimeout)
    }
  }
}

/// Leave a topic. The socket stays open and usable for its other channels.
pub fn leave(
  socket: Socket,
  topic: String,
  join_ref: String,
) -> Result(Nil, AquamarineError) {
  let reply_to = process.new_subject()
  process.send(socket.subject, Leave(topic, join_ref, reply_to))

  case process.receive(reply_to, call_timeout_ms) {
    Ok(result) -> result
    Error(Nil) -> Error(error.Transport(error.Timeout))
  }
}

/// Push an event to a topic. Fire-and-forget.
///
/// There is no synchronous result: a send that fails takes the socket down,
/// which channels observe as an error event. Not needing a reply is what keeps
/// the outbound path to a single hop.
pub fn push(
  socket: Socket,
  join_ref: String,
  topic: String,
  event: String,
  payload: json.Json,
) -> Nil {
  process.send(socket.subject, Push(join_ref, topic, event, payload))
}

/// Push an event and block until the reply carrying its ref arrives.
///
/// The reply is routed to this caller instead of to the topic's channel.
/// Frames that arrive in the meantime still reach their channels — they are
/// not dropped, which is the whole reason the pending table exists.
///
/// On timeout the pending entry is dropped, so a caller that gives up does not
/// leak an entry; a reply that arrives afterwards falls through to the topic's
/// channel like any other unclaimed frame.
pub fn push_and_await_reply(
  socket: Socket,
  join_ref: String,
  topic: String,
  event: String,
  payload: json.Json,
  timeout: Int,
) -> Result(Incoming, AquamarineError) {
  let reply_to = process.new_subject()
  process.send(
    socket.subject,
    PushAwaitingReply(join_ref, topic, event, payload, reply_to),
  )

  case process.receive(reply_to, timeout) {
    Ok(result) -> result
    Error(Nil) -> {
      // We do not know the ref the actor minted, so cancel by subject rather
      // than by ref.
      process.send(socket.subject, CancelPush(reply_to))
      Error(error.ReplyTimeout)
    }
  }
}

/// Close the connection and stop the actor. Every joined channel goes with it.
pub fn close(socket: Socket) -> Result(Nil, AquamarineError) {
  let reply_to = process.new_subject()
  process.send(socket.subject, Close(reply_to))

  case process.receive(reply_to, call_timeout_ms) {
    Ok(result) -> result
    Error(Nil) -> Error(error.Transport(error.Timeout))
  }
}

fn handle(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    Inbound(frame) -> handle_frame(state, frame)

    Push(join_ref, topic, event, payload) ->
      case state.gone {
        True -> actor.continue(state)
        False -> {
          let #(ref, state) = mint_ref(state)
          let text =
            state.codec.encode_push(join_ref, ref, topic, event, payload)
          case state.transport.send_text(text) {
            Ok(Nil) -> actor.continue(state)
            Error(err) -> actor.continue(lose_socket(state, err))
          }
        }
      }

    Join(topic, payload, events, reply_to) ->
      case join_refusal(state, topic) {
        Some(err) -> {
          process.send(reply_to, Error(err))
          actor.continue(state)
        }
        None -> {
          let #(join_ref, state) = mint_ref(state)
          let text = state.codec.encode_join(join_ref, topic, payload)
          // Register the route now rather than on acceptance. A server push
          // that arrives before the join reply would otherwise have nowhere to
          // go, which is the dropped-frame bug in a new costume. The route is
          // withdrawn again if the join is rejected, abandoned, or never sent.
          let state =
            State(..state, routes: dict.insert(state.routes, topic, events))
          send_awaiting(
            state,
            join_ref,
            text,
            JoinWaiter(topic, events, reply_to),
            fn(err) { process.send(reply_to, Error(err)) },
          )
        }
      }

    Leave(topic, join_ref, reply_to) -> {
      // Drop the route first: a leave means this channel wants no more frames,
      // whether or not the leave frame makes it out.
      let state = State(..state, routes: dict.delete(state.routes, topic))
      case state.gone {
        True -> {
          process.send(reply_to, Ok(Nil))
          actor.continue(state)
        }
        False -> {
          let #(ref, state) = mint_ref(state)
          let text =
            state.codec.encode_push(
              join_ref,
              ref,
              topic,
              state.codec.leave_event,
              json.object([]),
            )
          case state.transport.send_text(text) {
            Ok(Nil) -> {
              process.send(reply_to, Ok(Nil))
              actor.continue(state)
            }
            Error(err) -> {
              process.send(reply_to, Error(err))
              actor.continue(lose_socket(state, err))
            }
          }
        }
      }
    }

    PushAwaitingReply(join_ref, topic, event, payload, reply_to) ->
      case state.gone {
        True -> {
          process.send(reply_to, Error(error.ChannelClosed))
          actor.continue(state)
        }
        False -> {
          let #(ref, state) = mint_ref(state)
          let text =
            state.codec.encode_push(join_ref, ref, topic, event, payload)
          send_awaiting(state, ref, text, ReplyWaiter(reply_to), fn(err) {
            process.send(reply_to, Error(err))
          })
        }
      }

    // The caller gave up. Drop the entry so the table cannot grow unbounded.
    // A reply that arrives afterwards falls through to the topic's channel
    // like any other unclaimed frame.
    CancelPush(reply_to) ->
      actor.continue(
        drop_waiter(state, fn(waiter) {
          case waiter {
            ReplyWaiter(rt) -> rt == reply_to
            JoinWaiter(..) -> False
          }
        }),
      )

    CancelJoin(reply_to) ->
      actor.continue(
        drop_waiter(state, fn(waiter) {
          case waiter {
            JoinWaiter(_, _, rt) -> rt == reply_to
            ReplyWaiter(_) -> False
          }
        }),
      )

    // A gone socket stops beating: no frame, and no rescheduling.
    Heartbeat ->
      case state.gone {
        True -> actor.continue(State(..state, heartbeat_timer: None))
        False -> {
          let #(ref, state) = mint_ref(state)
          let state =
            State(
              ..state,
              heartbeat_timer: Some(process.send_after(
                state.self,
                state.heartbeat_ms,
                Heartbeat,
              )),
            )
          case state.transport.send_text(state.codec.encode_heartbeat(ref)) {
            Ok(Nil) -> actor.continue(state)
            Error(err) -> actor.continue(lose_socket(state, err))
          }
        }
      }

    Close(reply_to) -> {
      cancel_heartbeat(state)
      // A deliberate close is still a close as far as anyone waiting on a
      // reply — or holding a channel — is concerned.
      fail_pending(state, error.ChannelClosed)
      broadcast(state, error.ChannelClosed)
      // Close the transport even when the socket is already known to be gone —
      // the underlying resource still needs releasing. Its complaint about
      // being closed twice is not worth reporting, though.
      let result = case state.transport.close(), state.gone {
        _, True -> Ok(Nil)
        result, False -> result
      }
      process.send(reply_to, result)
      actor.stop()
    }
  }
}

/// Why this join cannot proceed, if it cannot.
fn join_refusal(state: State, topic: String) -> Option(AquamarineError) {
  case state.gone, dict.has_key(state.routes, topic), topic {
    True, _, _ -> Some(error.ChannelClosed)
    // Silently replacing the routing entry would orphan the first channel's
    // subject with no error raised anywhere — the worst available outcome.
    _, True, _ -> Some(error.AlreadyJoined(topic))
    // The heartbeat topic is the socket's own. Handing it to a channel would
    // route heartbeat replies into application code.
    _, _, t if t == state.codec.heartbeat_topic ->
      Some(error.ReservedTopic(topic))
    _, _, _ -> None
  }
}

fn handle_frame(
  state: State,
  frame: transport.Frame,
) -> actor.Next(State, Message) {
  case frame {
    transport.Text(text) ->
      case state.codec.decode(text) {
        Ok(incoming) -> route(state, incoming)
        // A frame we cannot decode has no topic to route by, so it is a
        // socket-level fault rather than a channel event. Tell every channel,
        // and tell anyone blocked on a reply rather than leaving them to time
        // out on a socket that is talking nonsense. The connection is left
        // alone.
        Error(err) -> {
          let err = error.DecodeFailed(err)
          broadcast(state, err)
          fail_pending(state, err)
          actor.continue(State(..state, pending: dict.new()))
        }
      }

    // Binary frames carry no channel semantics under any codec we support.
    transport.Binary(_) -> actor.continue(state)

    transport.Closed -> actor.continue(lose_socket(state, error.ChannelClosed))
  }
}

/// Send a frame and register its ref as pending, so the reply comes back to
/// the caller rather than to the topic's channel. Registration happens before
/// the send is observable, because the reply can arrive immediately.
fn send_awaiting(
  state: State,
  ref: String,
  text: String,
  waiter: Waiter,
  on_error: fn(AquamarineError) -> Nil,
) -> actor.Next(State, Message) {
  let state = State(..state, pending: dict.insert(state.pending, ref, waiter))
  case state.transport.send_text(text) {
    Ok(Nil) -> actor.continue(state)
    Error(err) -> {
      let state = State(..state, pending: dict.delete(state.pending, ref))
      // A join that never left withdraws its provisional route.
      let state = case waiter {
        JoinWaiter(topic, _, _) ->
          State(..state, routes: dict.delete(state.routes, topic))
        ReplyWaiter(_) -> state
      }
      on_error(err)
      actor.continue(lose_socket(state, err))
    }
  }
}

/// Decide where a decoded frame goes: to whoever is waiting on its ref, or to
/// the channel that joined its topic.
fn route(state: State, incoming: Incoming) -> actor.Next(State, Message) {
  case correlate(state, incoming) {
    Ok(#(ref, waiter)) -> {
      let state = State(..state, pending: dict.delete(state.pending, ref))
      actor.continue(deliver(state, waiter, ref, incoming))
    }
    Error(Nil) -> actor.continue(to_channel(state, incoming))
  }
}

/// Find the pending waiter this frame answers, if any.
///
/// Matching goes through `codec.matches_reply` rather than comparing
/// `incoming.ref` directly, so protocols that correlate some other way — or
/// cannot correlate at all — keep working. A codec that never matches simply
/// never resolves a waiter, and the caller's timeout takes over.
fn correlate(
  state: State,
  incoming: Incoming,
) -> Result(#(String, Waiter), Nil) {
  state.pending
  |> dict.to_list
  |> list.find(fn(entry) { state.codec.matches_reply(incoming, entry.0) })
}

fn deliver(
  state: State,
  waiter: Waiter,
  ref: String,
  incoming: Incoming,
) -> State {
  case waiter {
    // The actor owns the codec, so it is also the thing that knows how to read
    // a join reply's status. The caller gets a verdict, not a frame to
    // interpret. A join is only routable once the server has accepted it.
    JoinWaiter(topic, _events, reply_to) ->
      case state.codec.reply_status(incoming) {
        Ok(Nil) -> {
          process.send(reply_to, Ok(Joined(ref, incoming)))
          state
        }
        // Rejected: withdraw the provisional route.
        Error(reason) -> {
          process.send(reply_to, Error(error.JoinRejected(reason)))
          State(..state, routes: dict.delete(state.routes, topic))
        }
      }
    // A push reply carrying a non-ok status is an ordinary reply. Interpreting
    // it is the caller's business, not ours.
    ReplyWaiter(reply_to) -> {
      process.send(reply_to, Ok(incoming))
      state
    }
  }
}

/// Deliver a frame to the channel that joined its topic.
///
/// A frame for a topic nobody joined is dropped, never a crash. Heartbeat
/// replies arrive on the reserved heartbeat topic, which never has a channel,
/// so they fall out here as ordinary unknown-topic drops — no special case
/// needed.
fn to_channel(state: State, incoming: Incoming) -> State {
  case dict.get(state.routes, incoming.topic) {
    Error(Nil) -> {
      logging.log(
        logging.Debug,
        "aquamarine: dropping frame for unjoined topic " <> incoming.topic,
      )
      state
    }
    Ok(events) ->
      case incoming.event {
        // Close and error events terminate *this* topic's channel. The socket
        // and every other channel are unaffected.
        e if e == state.codec.close_event || e == state.codec.error_event -> {
          process.send(events, Error(error.ChannelClosed))
          State(..state, routes: dict.delete(state.routes, incoming.topic))
        }
        _ -> {
          process.send(events, Ok(incoming))
          state
        }
      }
  }
}

/// The socket is gone. Tell every channel, fail everyone waiting on a reply,
/// and record it so later messages get an answer instead of silence.
fn lose_socket(state: State, err: AquamarineError) -> State {
  case state.gone {
    True -> state
    False -> {
      broadcast(state, err)
      fail_pending(state, err)
      cancel_heartbeat(state)
      State(..state, pending: dict.new(), heartbeat_timer: None, gone: True)
    }
  }
}

/// Report a socket-level error to every joined channel.
fn broadcast(state: State, err: AquamarineError) -> Nil {
  use events <- list.each(dict.values(state.routes))
  process.send(events, Error(err))
}

/// Fail everyone waiting on a reply. A caller blocked in
/// `push_and_await_reply` must never outlive the socket it is waiting on.
fn fail_pending(state: State, err: AquamarineError) -> Nil {
  use waiter <- list.each(dict.values(state.pending))
  case waiter {
    JoinWaiter(_, _, reply_to) -> process.send(reply_to, Error(err))
    ReplyWaiter(reply_to) -> process.send(reply_to, Error(err))
  }
}

/// Remove the pending entry whose waiter matches.
fn drop_waiter(state: State, matches: fn(Waiter) -> Bool) -> State {
  State(
    ..state,
    pending: dict.filter(state.pending, fn(_ref, waiter) { !matches(waiter) }),
  )
}

/// Cancel the pending heartbeat so no stray tick outlives the actor.
fn cancel_heartbeat(state: State) -> Nil {
  case state.heartbeat_timer {
    Some(timer) -> {
      let _ = process.cancel_timer(timer)
      Nil
    }
    None -> Nil
  }
}

/// Take the next ref. Monotonic and unique for the life of the socket.
fn mint_ref(state: State) -> #(String, State) {
  #(int.to_string(state.next_ref), State(..state, next_ref: state.next_ref + 1))
}
