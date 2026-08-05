//// The socket: one WebSocket connection, many topics, reconnected for you.
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
//// ## Reconnect
////
//// An unexpected disconnect does not kill the socket. It moves to a
//// reconnecting state, retries on a capped exponential backoff, and on
//// success rejoins every topic that was joined before the drop — with its
//// original payload and a fresh join ref. `Channel` handles stay valid
//// throughout: the actor is the same process, so their events subjects still
//// work.
////
//// A deliberate [`close`](#close), and a [`leave`](#leave) of a topic, never
//// trigger any of this.
////
//// What a caller has to know:
////
//// - **Pushes issued while disconnected do not go out.** Nothing is buffered;
////   buffering would create delivery expectations the library cannot honour.
////   [`push_and_await_reply`](#push_and_await_reply) returns
////   `Error(Disconnected)`. Plain [`push`](#push) is fire-and-forget and has
////   no way to tell you, so it is dropped with a debug log — watch the status
////   stream if you need to know.
//// - **Pending replies are failed at the disconnect**, with `ChannelClosed`.
////   They are never re-correlated against the new connection.
//// - **Refs keep counting up across a reconnect.** Resetting would let a
////   stale in-flight reply correlate against a fresh ref.
//// - **A rejoin the server refuses ends that channel**, with
////   `RejoinRejected`. The rest of the socket carries on.
////
//// [`watch`](#watch) subscribes to [`Status`](#Status) events so an
//// application can see the connection drop and come back — a resubscribe or a
//// refetch is often needed at the application level, and only the application
//// knows that.
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
//// **A restart is not a reconnect.** Reconnect happens inside a living actor
//// and keeps your handles; a supervisor restart replaces the actor, so the
//// new socket comes back with nothing joined and every prior `Channel` handle
//// is stale — its events subject belonged to the dead actor. Restart is the
//// backstop for a socket that crashed, not the mechanism for a dropped
//// connection.
////
//// ## Process ownership
////
//// The actor owns everything with state: the transport, the inbound sink, the
//// ref counter, the heartbeat timer, and the routing table. Each channel's
//// events subject is owned by whoever created it — normally the process that
//// called `channel.join` — and only that process may receive from it.
//// Everything in this module is safe to call from any process.

import aquamarine/backoff.{type Backoff}
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

/// Connection lifecycle events, for callers who need to know that the
/// connection dropped and came back.
///
/// These go to a separate subject rather than into the channel event stream,
/// so [`channel.receive`](aquamarine/channel.html#receive) keeps meaning
/// exactly "the next thing that happened on my topic".
pub type Status {
  /// Connected, or reconnected. Rejoins have not been attempted yet.
  Connected
  /// The connection dropped unexpectedly. A reconnect follows.
  Disconnected(reason: AquamarineError)
  /// About to retry, after `delay_ms`.
  Reconnecting(attempt: Int, delay_ms: Int)
  /// A topic was successfully rejoined after a reconnect.
  Rejoined(topic: String)
  /// The server refused a rejoin. That channel is finished; the socket is not.
  RejoinFailed(topic: String, reason: AquamarineError)
  /// Reconnect hit the configured attempt limit and stopped trying.
  GaveUp(attempts: Int)
}

/// Handle to a running socket actor.
pub opaque type Socket {
  Socket(subject: Subject(Message))
}

/// A successful join: the ref the join was sent under, and the reply the
/// server accepted it with.
pub type Joined {
  Joined(join_ref: String, reply: Incoming)
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

/// Everything needed to open a socket.
pub opaque type Config {
  Config(
    connector: Connector,
    codec: Codec,
    heartbeat_ms: Int,
    backoff: Backoff,
  )
}

pub opaque type Message {
  /// An inbound frame, pushed here by the transport.
  Inbound(transport.Frame)
  /// Join a topic. The actor mints the join ref, encodes the frame, sends it,
  /// routes the matching reply to `reply_to`, and registers `events` as the
  /// destination for that topic's frames.
  Join(
    topic: String,
    payload: json.Json,
    events: Subject(Event),
    reply_to: Subject(Result(Joined, AquamarineError)),
  )
  /// Leave a topic: send the leave frame and forget the topic entirely, so a
  /// later reconnect does not rejoin it.
  Leave(topic: String, reply_to: Subject(Result(Nil, AquamarineError)))
  /// Fire-and-forget push. The actor mints the ref and stamps the topic's
  /// current join ref, which is why a rejoin is invisible to the caller.
  Push(topic: String, event: String, payload: json.Json)
  /// Push whose reply is routed back to `reply_to` instead of to the topic's
  /// channel. The actor registers the ref before sending it.
  PushAwaitingReply(
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
  /// Try to re-open the connection.
  Reconnect
  Watch(watcher: Subject(Status))
  Unwatch(watcher: Subject(Status))
  Close(reply_to: Subject(Result(Nil, AquamarineError)))
}

/// A caller blocked on the reply to a specific outbound ref.
///
/// The three kinds want different things from one mechanism: a join wants a
/// verdict (`JoinRejected` is an error), a rejoin has nobody waiting on it and
/// reports through the status stream instead, and a push reply carrying a
/// non-ok status is a perfectly ordinary reply the caller should see.
type Waiter {
  JoinWaiter(topic: String, reply_to: Subject(Result(Joined, AquamarineError)))
  RejoinWaiter(topic: String)
  ReplyWaiter(reply_to: Subject(Event))
}

/// A joined topic: where its frames go, and what it takes to join it again.
type Topic {
  Topic(events: Subject(Event), payload: json.Json, join_ref: String)
}

/// The connection, which outlives any particular transport.
type Conn {
  Live(transport: Transport)
  /// Between connections. `attempt` counts consecutive failures.
  Retrying(attempt: Int)
  /// Closed deliberately, or out of retries. Terminal.
  Dead
}

type State {
  State(
    self: Subject(Message),
    /// Reused across reconnects — it belongs to the actor, not to a transport.
    sink: Subject(transport.Frame),
    connector: Connector,
    codec: Codec,
    conn: Conn,
    /// Joined topics, keyed by name. Doubles as the routing table and as the
    /// list of what to rejoin after a reconnect.
    topics: Dict(String, Topic),
    /// Callers blocked on a reply, keyed by the ref their frame went out
    /// under. This table is the thing a single blocking `receive` could not
    /// express: with it, a frame nobody asked for still has somewhere to go.
    pending: Dict(String, Waiter),
    /// How often to emit a heartbeat, and the timer for the next one. The
    /// heartbeat is a self-message on a timer rather than a second actor —
    /// once the socket owns both the counter and the transport, that is all it
    /// ever needed to be.
    ///
    /// It runs for the life of the connection regardless of how many channels
    /// are joined, matching the Phoenix JS client: the heartbeat lives on the
    /// socket, not the channel.
    heartbeat_ms: Int,
    heartbeat_timer: Option(process.Timer),
    backoff: Backoff,
    watchers: List(Subject(Status)),
    /// Next ref to mint. Refs are minted inside the actor, in the same handler
    /// that sends the frame carrying them, so ref order and send order cannot
    /// diverge. It keeps counting across a reconnect, so a stale in-flight
    /// reply can never correlate against a fresh ref.
    next_ref: Int,
  )
}

// -- configuration ----------------------------------------------------------

/// Configuration for a socket, with default heartbeat and backoff.
pub fn config(
  scheme scheme: transport.Scheme,
  host host: String,
  port port: Int,
  path path: String,
  codec codec: Codec,
) -> Config {
  Config(
    connector: transport.collie_connector(scheme:, host:, port:, path:),
    codec: codec,
    heartbeat_ms: default_heartbeat_ms,
    backoff: backoff.default(),
  )
}

/// Replace the reconnect schedule.
pub fn with_backoff(config: Config, backoff: Backoff) -> Config {
  Config(..config, backoff: backoff)
}

/// Replace the heartbeat interval.
pub fn with_heartbeat_ms(config: Config, ms: Int) -> Config {
  Config(..config, heartbeat_ms: ms)
}

/// Swap in an in-memory transport. For tests.
@internal
pub fn with_connector(config: Config, connector: Connector) -> Config {
  Config(..config, connector: connector)
}

/// Configuration around an arbitrary connector. For tests.
@internal
pub fn test_config(connector: Connector, codec: Codec) -> Config {
  Config(
    connector: connector,
    codec: codec,
    heartbeat_ms: default_heartbeat_ms,
    backoff: backoff.default(),
  )
}

// -- lifecycle --------------------------------------------------------------

/// Open a WebSocket to a compatible server.
///
/// The connection carries no topics until something joins one. The codec
/// belongs to the socket, not to a channel: the socket has to decode every
/// frame to read its topic before it can route, so one socket serves one wire
/// protocol — matching Phoenix's one-serializer-per-socket model.
pub fn connect(
  scheme scheme: transport.Scheme,
  host host: String,
  port port: Int,
  path path: String,
  codec codec: Codec,
) -> Result(Socket, AquamarineError) {
  start(config(scheme:, host:, port:, path:, codec:))
}

/// Open a WebSocket with an explicit configuration.
pub fn start(config: Config) -> Result(Socket, AquamarineError) {
  start_named(config, None)
}

/// Start a socket, optionally registering it under a name.
@internal
pub fn start_named(
  config: Config,
  name: Option(Name),
) -> Result(Socket, AquamarineError) {
  // The connector runs inside the actor's initialiser, where the only failure
  // channel is a `String`. Route the typed error out of band.
  let failure = process.new_subject()

  case actor.start(build(config, name, failure)) {
    Ok(started) -> Ok(Socket(subject: started.data))
    Error(_) ->
      case process.receive(failure, 0) {
        Ok(err) -> Error(err)
        Error(Nil) -> Error(error.InternalError("failed to start socket actor"))
      }
  }
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
/// A dropped connection does not reach the supervisor at all — the actor stays
/// alive and reconnects itself. This is the backstop for a socket that
/// crashed, and a restarted socket has **no joined channels**, with every
/// prior `Channel` handle stale. See the module documentation.
pub fn supervised(
  config: Config,
  name: Name,
) -> supervision.ChildSpecification(Socket) {
  supervision.worker(fn() {
    build(config, Some(name), process.new_subject())
    |> actor.start
    |> result.map(fn(started: actor.Started(Subject(Message))) {
      actor.Started(pid: started.pid, data: Socket(subject: started.data))
    })
  })
  |> supervision.restart(supervision.Transient)
}

fn build(
  config: Config,
  name: Option(Name),
  failure: Subject(AquamarineError),
) -> actor.Builder(State, Message, Subject(Message)) {
  let builder =
    actor.new_with_initialiser(init_timeout_ms, fn(self) {
      let sink = process.new_subject()
      case config.connector(sink) {
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
            sink: sink,
            connector: config.connector,
            codec: config.codec,
            conn: Live(tx),
            topics: dict.new(),
            pending: dict.new(),
            heartbeat_ms: config.heartbeat_ms,
            heartbeat_timer: Some(process.send_after(
              self,
              config.heartbeat_ms,
              Heartbeat,
            )),
            backoff: config.backoff,
            watchers: [],
            next_ref: 1,
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

// -- operations -------------------------------------------------------------

/// Receive [`Status`](#Status) events on the given subject.
///
/// Only the process that created the subject can receive from it. Watching
/// twice with the same subject is harmless.
pub fn watch(socket: Socket, watcher: Subject(Status)) -> Nil {
  process.send(socket.subject, Watch(watcher))
}

/// Stop receiving status events on the given subject.
pub fn unwatch(socket: Socket, watcher: Subject(Status)) -> Nil {
  process.send(socket.subject, Unwatch(watcher))
}

/// Join a topic and block until the server replies.
///
/// On acceptance, `events` becomes the destination for that topic's inbound
/// frames, and the topic is remembered so a reconnect rejoins it. Frames for
/// other topics that arrive in the meantime still reach their own channels.
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

/// Leave a topic. The socket stays open and usable for its other channels,
/// and a later reconnect will not rejoin this topic.
pub fn leave(socket: Socket, topic: String) -> Result(Nil, AquamarineError) {
  let reply_to = process.new_subject()
  process.send(socket.subject, Leave(topic, reply_to))

  case process.receive(reply_to, call_timeout_ms) {
    Ok(result) -> result
    Error(Nil) -> Error(error.Transport(error.Timeout))
  }
}

/// Push an event to a topic. Fire-and-forget.
///
/// There is no synchronous result, and therefore no way to tell you that the
/// socket was disconnected when this was called — such a push is dropped with
/// a debug log. Use [`push_and_await_reply`](#push_and_await_reply) when you
/// need to know, or [`watch`](#watch) to track the connection.
pub fn push(
  socket: Socket,
  topic: String,
  event: String,
  payload: json.Json,
) -> Nil {
  process.send(socket.subject, Push(topic, event, payload))
}

/// Push an event and block until the reply carrying its ref arrives.
///
/// The reply is routed to this caller instead of to the topic's channel.
/// Frames that arrive in the meantime still reach their channels — they are
/// not dropped, which is the whole reason the pending table exists.
///
/// Returns `Error(Disconnected)` immediately if the socket is between
/// connections. Nothing is buffered: buffering would create delivery
/// expectations this library cannot honour.
///
/// On timeout the pending entry is dropped, so a caller that gives up does not
/// leak an entry; a reply that arrives afterwards falls through to the topic's
/// channel like any other unclaimed frame.
pub fn push_and_await_reply(
  socket: Socket,
  topic: String,
  event: String,
  payload: json.Json,
  timeout: Int,
) -> Result(Incoming, AquamarineError) {
  let reply_to = process.new_subject()
  process.send(
    socket.subject,
    PushAwaitingReply(topic, event, payload, reply_to),
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

/// Close the connection and stop the actor. Every joined channel goes with it,
/// and no reconnect is attempted.
pub fn close(socket: Socket) -> Result(Nil, AquamarineError) {
  let reply_to = process.new_subject()
  process.send(socket.subject, Close(reply_to))

  case process.receive(reply_to, call_timeout_ms) {
    Ok(result) -> result
    Error(Nil) -> Error(error.Transport(error.Timeout))
  }
}

// -- the actor --------------------------------------------------------------

fn handle(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    Inbound(frame) -> handle_frame(state, frame)

    Push(topic, event, payload) ->
      case live(state), dict.get(state.topics, topic) {
        Some(tx), Ok(joined) -> {
          let #(ref, state) = mint_ref(state)
          state.codec.encode_push(joined.join_ref, ref, topic, event, payload)
          |> tx.send_text
          actor.continue(state)
        }
        _, _ -> {
          logging.log(
            logging.Debug,
            "aquamarine: dropping push to "
              <> topic
              <> " — socket not connected or topic not joined",
          )
          actor.continue(state)
        }
      }

    Join(topic, payload, events, reply_to) ->
      case join_refusal(state, topic) {
        Some(err) -> {
          process.send(reply_to, Error(err))
          actor.continue(state)
        }
        None -> {
          let assert Some(tx) = live(state)
          let #(join_ref, state) = mint_ref(state)
          // Register the topic now rather than on acceptance. A server push
          // that arrives before the join reply would otherwise have nowhere to
          // go, which is the dropped-frame bug in a new costume. The entry is
          // withdrawn again if the join is rejected or abandoned.
          let state =
            State(
              ..state,
              topics: dict.insert(
                state.topics,
                topic,
                Topic(events:, payload:, join_ref:),
              ),
              pending: dict.insert(
                state.pending,
                join_ref,
                JoinWaiter(topic, reply_to),
              ),
            )
          tx.send_text(state.codec.encode_join(join_ref, topic, payload))
          actor.continue(state)
        }
      }

    Leave(topic, reply_to) -> {
      // Forget the topic first: a leave means this channel wants no more
      // frames and no rejoin, whether or not the leave frame makes it out.
      let joined = dict.get(state.topics, topic)
      let state = State(..state, topics: dict.delete(state.topics, topic))

      case live(state), joined {
        Some(tx), Ok(joined) -> {
          let #(ref, state) = mint_ref(state)
          state.codec.encode_push(
            joined.join_ref,
            ref,
            topic,
            state.codec.leave_event,
            json.object([]),
          )
          |> tx.send_text
          process.send(reply_to, Ok(Nil))
          actor.continue(state)
        }
        // Disconnected, or never joined: dropping the entry is the whole of
        // what leaving means here.
        _, _ -> {
          process.send(reply_to, Ok(Nil))
          actor.continue(state)
        }
      }
    }

    PushAwaitingReply(topic, event, payload, reply_to) ->
      case live(state), dict.get(state.topics, topic) {
        Some(tx), Ok(joined) -> {
          let #(ref, state) = mint_ref(state)
          let state =
            State(
              ..state,
              pending: dict.insert(state.pending, ref, ReplyWaiter(reply_to)),
            )
          state.codec.encode_push(joined.join_ref, ref, topic, event, payload)
          |> tx.send_text
          actor.continue(state)
        }
        None, _ -> {
          process.send(reply_to, Error(disconnect_error(state)))
          actor.continue(state)
        }
        _, Error(Nil) -> {
          process.send(reply_to, Error(error.ChannelClosed))
          actor.continue(state)
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
            _ -> False
          }
        }),
      )

    // An abandoned join takes its provisional topic entry with it.
    CancelJoin(reply_to) -> {
      let abandoned =
        state.pending
        |> dict.values
        |> list.filter_map(fn(waiter) {
          case waiter {
            JoinWaiter(topic, rt) if rt == reply_to -> Ok(topic)
            _ -> Error(Nil)
          }
        })
      let state =
        State(
          ..state,
          topics: list.fold(abandoned, state.topics, fn(topics, topic) {
            dict.delete(topics, topic)
          }),
        )
      actor.continue(
        drop_waiter(state, fn(waiter) {
          case waiter {
            JoinWaiter(_, rt) -> rt == reply_to
            _ -> False
          }
        }),
      )
    }

    // Only a live connection beats.
    Heartbeat ->
      case live(state) {
        None -> actor.continue(State(..state, heartbeat_timer: None))
        Some(tx) -> {
          let #(ref, state) = mint_ref(state)
          tx.send_text(state.codec.encode_heartbeat(ref))
          actor.continue(schedule_heartbeat(state))
        }
      }

    Reconnect -> attempt_reconnect(state)

    Watch(watcher) ->
      case list.contains(state.watchers, watcher) {
        True -> actor.continue(state)
        False ->
          actor.continue(State(..state, watchers: [watcher, ..state.watchers]))
      }

    Unwatch(watcher) ->
      actor.continue(
        State(
          ..state,
          watchers: list.filter(state.watchers, fn(w) { w != watcher }),
        ),
      )

    Close(reply_to) -> {
      cancel_heartbeat(state)
      // A deliberate close is still a close as far as anyone waiting on a
      // reply — or holding a channel — is concerned. And it never reconnects.
      fail_pending(state, error.ChannelClosed)
      broadcast(state, error.ChannelClosed)
      let result = case state.conn {
        // Close the transport even when the connection is already known to be
        // gone; its complaint about being closed twice is not worth reporting.
        Live(tx) -> tx.close()
        _ -> Ok(Nil)
      }
      process.send(reply_to, result)
      actor.stop()
    }
  }
}

/// The live transport, if there is one.
fn live(state: State) -> Option(Transport) {
  case state.conn {
    Live(tx) -> Some(tx)
    _ -> None
  }
}

fn disconnect_error(state: State) -> AquamarineError {
  case state.conn {
    Dead -> error.ChannelClosed
    _ -> error.Disconnected
  }
}

/// Why this join cannot proceed, if it cannot.
fn join_refusal(state: State, topic: String) -> Option(AquamarineError) {
  case state.conn, dict.has_key(state.topics, topic), topic {
    Dead, _, _ -> Some(error.ChannelClosed)
    Retrying(_), _, _ -> Some(error.Disconnected)
    // Silently replacing the entry would orphan the first channel's subject
    // with no error raised anywhere — the worst available outcome.
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

    // A `Closed` while already retrying is the echo of the connection we just
    // lost, not a new event.
    transport.Closed ->
      case state.conn {
        Live(_) -> begin_reconnect(state, error.ChannelClosed)
        _ -> actor.continue(state)
      }
  }
}

// -- reconnect --------------------------------------------------------------

/// The connection dropped unexpectedly. Tear down what cannot survive it, keep
/// what can, and schedule the first retry.
fn begin_reconnect(
  state: State,
  reason: AquamarineError,
) -> actor.Next(State, Message) {
  cancel_heartbeat(state)
  // Pending replies belong to the connection that just died. Failing them is
  // the only honest answer — they must never be re-correlated against the new
  // connection.
  fail_pending(state, error.ChannelClosed)
  notify(state, Disconnected(reason))

  // Topics are kept: they are what a rejoin is made of.
  State(..state, conn: Retrying(0), pending: dict.new(), heartbeat_timer: None)
  |> schedule_reconnect
}

fn schedule_reconnect(state: State) -> actor.Next(State, Message) {
  let attempts = case state.conn {
    Retrying(attempt) -> attempt
    _ -> 0
  }

  case backoff.may_retry(state.backoff, attempts) {
    False -> {
      notify(state, GaveUp(attempts))
      broadcast(state, error.ReconnectFailed(attempts))
      actor.continue(State(..state, conn: Dead, topics: dict.new()))
    }
    True -> {
      let attempt = attempts + 1
      let delay = backoff.delay_ms(state.backoff, attempt)
      notify(state, Reconnecting(attempt, delay))
      let _ = process.send_after(state.self, delay, Reconnect)
      actor.continue(State(..state, conn: Retrying(attempt)))
    }
  }
}

fn attempt_reconnect(state: State) -> actor.Next(State, Message) {
  case state.conn {
    // A close or a successful reconnect beat this timer to it.
    Live(_) | Dead -> actor.continue(state)
    Retrying(_) ->
      case state.connector(state.sink) {
        Error(_) -> schedule_reconnect(state)
        Ok(tx) -> {
          notify(state, Connected)
          State(..state, conn: Live(tx))
          |> schedule_heartbeat
          |> rejoin_all
        }
      }
  }
}

/// Rejoin every topic that was joined before the drop, with its original
/// payload and a fresh join ref.
fn rejoin_all(state: State) -> actor.Next(State, Message) {
  let state =
    dict.keys(state.topics)
    |> list.fold(state, fn(state, topic) {
      case live(state), dict.get(state.topics, topic) {
        Some(tx), Ok(joined) -> {
          let #(join_ref, state) = mint_ref(state)
          tx.send_text(state.codec.encode_join(join_ref, topic, joined.payload))
          State(
            ..state,
            topics: dict.insert(
              state.topics,
              topic,
              Topic(..joined, join_ref: join_ref),
            ),
            pending: dict.insert(state.pending, join_ref, RejoinWaiter(topic)),
          )
        }
        _, _ -> state
      }
    })
  actor.continue(state)
}

// -- routing ----------------------------------------------------------------

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
    // interpret.
    JoinWaiter(topic, reply_to) ->
      case state.codec.reply_status(incoming) {
        Ok(Nil) -> {
          process.send(reply_to, Ok(Joined(ref, incoming)))
          state
        }
        // Rejected: withdraw the provisional topic entry.
        Error(reason) -> {
          process.send(reply_to, Error(error.JoinRejected(reason)))
          State(..state, topics: dict.delete(state.topics, topic))
        }
      }

    // Nobody is blocked on a rejoin, so it reports through the status stream —
    // and, when refused, through the channel's own events so the holder of
    // that `Channel` finds out rather than waiting forever on a topic the
    // server has forgotten.
    RejoinWaiter(topic) ->
      case state.codec.reply_status(incoming) {
        Ok(Nil) -> {
          notify(state, Rejoined(topic))
          state
        }
        Error(reason) -> {
          let err = error.RejoinRejected(topic, reason)
          notify(state, RejoinFailed(topic, err))
          case dict.get(state.topics, topic) {
            Ok(joined) -> process.send(joined.events, Error(err))
            Error(Nil) -> Nil
          }
          State(..state, topics: dict.delete(state.topics, topic))
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
  case dict.get(state.topics, incoming.topic) {
    Error(Nil) -> {
      logging.log(
        logging.Debug,
        "aquamarine: dropping frame for unjoined topic " <> incoming.topic,
      )
      state
    }
    Ok(joined) ->
      case incoming.event {
        // Close and error events terminate *this* topic's channel. The socket
        // and every other channel are unaffected, and the topic is forgotten
        // so a later reconnect does not resurrect it.
        e if e == state.codec.close_event || e == state.codec.error_event -> {
          process.send(joined.events, Error(error.ChannelClosed))
          State(..state, topics: dict.delete(state.topics, incoming.topic))
        }
        _ -> {
          process.send(joined.events, Ok(incoming))
          state
        }
      }
  }
}

// -- plumbing ---------------------------------------------------------------

/// Report a socket-level error to every joined channel.
fn broadcast(state: State, err: AquamarineError) -> Nil {
  use joined <- list.each(dict.values(state.topics))
  process.send(joined.events, Error(err))
}

/// Report a connection-lifecycle event to every watcher.
fn notify(state: State, status: Status) -> Nil {
  use watcher <- list.each(state.watchers)
  process.send(watcher, status)
}

/// Fail everyone waiting on a reply. A caller blocked in
/// `push_and_await_reply` must never outlive the connection it is waiting on.
fn fail_pending(state: State, err: AquamarineError) -> Nil {
  use waiter <- list.each(dict.values(state.pending))
  case waiter {
    JoinWaiter(_, reply_to) -> process.send(reply_to, Error(err))
    ReplyWaiter(reply_to) -> process.send(reply_to, Error(err))
    // Nobody is blocked on a rejoin.
    RejoinWaiter(_) -> Nil
  }
}

/// Remove the pending entry whose waiter matches.
fn drop_waiter(state: State, matches: fn(Waiter) -> Bool) -> State {
  State(
    ..state,
    pending: dict.filter(state.pending, fn(_ref, waiter) { !matches(waiter) }),
  )
}

fn schedule_heartbeat(state: State) -> State {
  State(
    ..state,
    heartbeat_timer: Some(process.send_after(
      state.self,
      state.heartbeat_ms,
      Heartbeat,
    )),
  )
}

/// Cancel the pending heartbeat so no stray tick outlives the connection.
fn cancel_heartbeat(state: State) -> Nil {
  case state.heartbeat_timer {
    Some(timer) -> {
      let _ = process.cancel_timer(timer)
      Nil
    }
    None -> Nil
  }
}

/// Take the next ref. Monotonic and unique for the life of the socket,
/// including across reconnects.
fn mint_ref(state: State) -> #(String, State) {
  #(int.to_string(state.next_ref), State(..state, next_ref: state.next_ref + 1))
}
