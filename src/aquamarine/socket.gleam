//// The socket actor: an OTP actor that owns the WebSocket transport.
////
//// Every inbound frame arrives in this actor's mailbox, is decoded through
//// the configured [`Codec`](aquamarine/codec.html#Codec), and is routed
//// onward — either to a caller waiting on a specific ref, or to the general
//// subscriber subject. The calling process never touches the socket.
////
//// ## Why an actor
////
//// A single blocking `receive` has nowhere to put a frame it is not currently
//// interested in, so waiting for a specific reply meant discarding everything
//// else. Here, a frame that nobody is waiting for goes to the subscriber and
//// sits in that mailbox until the caller gets to it.
////
//// ## Process ownership
////
//// The actor owns everything with state: the transport, the inbound sink, the
//// ref counter, and the heartbeat timer. The *subscriber* subject is owned by
//// whoever created it — normally the process that called `channel.connect` —
//// and only that process may receive from it. [`push`](#push),
//// [`join`](#join), and [`close`](#close) are safe from any process.
////
//// This module is `@internal` for now. It becomes public API once callers
//// need to open a socket and join several topics on it.

import aquamarine/codec.{type Codec, type Incoming}
import aquamarine/error.{type AquamarineError}
import aquamarine/transport.{type Connector, type Transport}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/otp/actor

/// How long the actor's initialiser — which runs the connector — may take.
const init_timeout_ms: Int = 30_000

/// How long [`close`](#close) waits for the actor to report the result of
/// closing the transport.
const close_timeout_ms: Int = 5000

/// What the subscriber receives.
///
/// Errors travel in-band because they are ordinary channel events from the
/// caller's point of view: the server closed the channel, a frame would not
/// decode, the socket went away.
@internal
pub type Event =
  Result(Incoming, AquamarineError)

/// Handle to a running socket actor.
@internal
pub opaque type Socket {
  Socket(subject: Subject(Message))
}

/// A successful join: the ref the join was sent under, and the reply the
/// server accepted it with.
@internal
pub type Joined {
  Joined(join_ref: String, reply: Incoming)
}

@internal
pub opaque type Message {
  /// An inbound frame, pushed here by the transport.
  Inbound(transport.Frame)
  /// Join a topic. The actor mints the join ref, encodes the frame, sends it,
  /// and routes the matching reply to `reply_to`.
  Join(
    topic: String,
    payload: json.Json,
    reply_to: Subject(Result(Joined, AquamarineError)),
  )
  /// Fire-and-forget push. The actor mints the ref.
  Push(join_ref: String, topic: String, event: String, payload: json.Json)
  /// Emit one heartbeat frame. The actor mints the ref.
  Heartbeat
  Close(reply_to: Subject(Result(Nil, AquamarineError)))
}

/// A caller blocked on the reply to a specific outbound ref.
type Waiter {
  Waiter(ref: String, reply_to: Subject(Result(Joined, AquamarineError)))
}

type State {
  State(
    self: Subject(Message),
    transport: Transport,
    codec: Codec,
    subscriber: Subject(Event),
    waiter: Option(Waiter),
    /// How often to emit a heartbeat, and the timer for the next one. The
    /// heartbeat is a self-message on a timer rather than a second actor —
    /// once the socket owns both the counter and the transport, that is all it
    /// ever needed to be.
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

/// Start a socket actor, opening the transport through `connector`.
///
/// The sink handed to the connector is created inside the actor, so inbound
/// frames arrive as ordinary actor messages.
@internal
pub fn start(
  connector: Connector,
  codec: Codec,
  subscriber: Subject(Event),
  heartbeat_ms: Int,
) -> Result(Socket, AquamarineError) {
  // The connector runs inside the actor's initialiser, where the only failure
  // channel is a `String`. Route the typed error out of band.
  let failure = process.new_subject()

  let started =
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
            subscriber: subscriber,
            waiter: None,
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
    |> actor.start

  case started {
    Ok(started) -> Ok(Socket(subject: started.data))
    Error(_) ->
      case process.receive(failure, 0) {
        Ok(err) -> Error(err)
        Error(Nil) -> Error(error.InternalError("failed to start socket actor"))
      }
  }
}

/// Push an event to the socket. Fire-and-forget.
///
/// There is no synchronous result: a send that fails takes the socket down,
/// which the subscriber observes as an error event. Not needing a reply is
/// what keeps the outbound path to a single hop.
@internal
pub fn push(
  socket: Socket,
  join_ref: String,
  topic: String,
  event: String,
  payload: json.Json,
) -> Nil {
  process.send(socket.subject, Push(join_ref, topic, event, payload))
}

/// Join a topic and block until the server replies.
///
/// The reply is routed to this caller instead of to the subscriber. Frames
/// that arrive in the meantime still reach the subscriber — they are not
/// dropped.
@internal
pub fn join(
  socket: Socket,
  topic: String,
  payload: json.Json,
  timeout: Int,
) -> Result(Joined, AquamarineError) {
  let reply_to = process.new_subject()
  process.send(socket.subject, Join(topic, payload, reply_to))

  case process.receive(reply_to, timeout) {
    Ok(result) -> result
    Error(Nil) -> Error(error.ReplyTimeout)
  }
}

/// Close the transport and stop the actor.
@internal
pub fn close(socket: Socket) -> Result(Nil, AquamarineError) {
  let reply_to = process.new_subject()
  process.send(socket.subject, Close(reply_to))

  case process.receive(reply_to, close_timeout_ms) {
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

    Join(topic, payload, reply_to) ->
      case state.gone {
        True -> {
          process.send(reply_to, Error(error.ChannelClosed))
          actor.continue(state)
        }
        False -> {
          let #(join_ref, state) = mint_ref(state)
          let text = state.codec.encode_join(join_ref, topic, payload)
          case state.transport.send_text(text) {
            Ok(Nil) ->
              actor.continue(
                State(..state, waiter: Some(Waiter(join_ref, reply_to))),
              )
            Error(err) -> {
              process.send(reply_to, Error(err))
              actor.continue(lose_socket(state, err))
            }
          }
        }
      }

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

fn handle_frame(
  state: State,
  frame: transport.Frame,
) -> actor.Next(State, Message) {
  case frame {
    transport.Text(text) ->
      case state.codec.decode(text) {
        Ok(incoming) -> route(state, incoming)
        // A frame we cannot decode is a protocol-level fault, not a channel
        // event. Tell the subscriber, and tell anyone blocked on a reply
        // rather than leaving them to time out on a socket that is talking
        // nonsense. The connection itself is left alone.
        Error(err) -> {
          let err = error.DecodeFailed(err)
          process.send(state.subscriber, Error(err))
          case state.waiter {
            Some(waiter) -> process.send(waiter.reply_to, Error(err))
            None -> Nil
          }
          actor.continue(State(..state, waiter: None))
        }
      }

    // Binary frames carry no channel semantics under any codec we support.
    transport.Binary(_) -> actor.continue(state)

    transport.Closed -> actor.continue(lose_socket(state, error.ChannelClosed))
  }
}

/// Decide where a decoded frame goes: to whoever is waiting on its ref, or to
/// the subscriber.
fn route(state: State, incoming: Incoming) -> actor.Next(State, Message) {
  case state.waiter {
    Some(waiter) ->
      case state.codec.matches_reply(incoming, waiter.ref) {
        True -> {
          // The actor owns the codec, so it is also the thing that knows how
          // to read a reply's status. The caller gets a verdict, not a frame
          // to interpret.
          let result = case state.codec.reply_status(incoming) {
            Ok(Nil) -> Ok(Joined(waiter.ref, incoming))
            Error(reason) -> Error(error.JoinRejected(reason))
          }
          process.send(waiter.reply_to, result)
          actor.continue(State(..state, waiter: None))
        }
        False -> {
          to_subscriber(state, incoming)
          actor.continue(state)
        }
      }
    None -> {
      to_subscriber(state, incoming)
      actor.continue(state)
    }
  }
}

fn to_subscriber(state: State, incoming: Incoming) -> Nil {
  case incoming.event {
    e if e == state.codec.close_event ->
      process.send(state.subscriber, Error(error.ChannelClosed))
    e if e == state.codec.error_event ->
      process.send(state.subscriber, Error(error.ChannelClosed))
    // Heartbeat replies are bookkeeping; they never reach the caller.
    e
      if e == state.codec.reply_event
      && incoming.topic == state.codec.heartbeat_topic
    -> Nil
    _ -> process.send(state.subscriber, Ok(incoming))
  }
}

/// The socket is gone. Tell the subscriber, fail anyone waiting on a reply,
/// and record it so later messages get an answer instead of silence.
fn lose_socket(state: State, err: AquamarineError) -> State {
  case state.gone {
    True -> state
    False -> {
      process.send(state.subscriber, Error(err))
      case state.waiter {
        Some(waiter) -> process.send(waiter.reply_to, Error(err))
        None -> Nil
      }
      cancel_heartbeat(state)
      State(..state, waiter: None, heartbeat_timer: None, gone: True)
    }
  }
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
