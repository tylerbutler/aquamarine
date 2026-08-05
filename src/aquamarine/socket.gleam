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
//// The actor owns the transport and the inbound sink. The *subscriber*
//// subject is owned by whoever created it — normally the process that called
//// `channel.connect` — and only that process may receive from it.
//// [`send`](#send), [`close`](#close), and
//// [`send_awaiting_reply`](#send_awaiting_reply) are safe from any process.
////
//// This module is `@internal` for now. It becomes public API once callers
//// need to open a socket and join several topics on it.

import aquamarine/codec.{type Codec, type Incoming}
import aquamarine/error.{type AquamarineError}
import aquamarine/transport.{type Connector, type Transport}
import gleam/erlang/process.{type Subject}
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

@internal
pub opaque type Message {
  /// An inbound frame, pushed here by the transport.
  Inbound(transport.Frame)
  /// Fire-and-forget outbound text.
  Send(text: String)
  /// Outbound text whose reply, matched by `ref`, goes to `reply_to` instead
  /// of to the subscriber.
  SendAwaitingReply(ref: String, text: String, reply_to: Subject(Event))
  Close(reply_to: Subject(Result(Nil, AquamarineError)))
}

/// A caller blocked on the reply to a specific outbound ref.
type Waiter {
  Waiter(ref: String, reply_to: Subject(Event))
}

type State {
  State(
    transport: Transport,
    codec: Codec,
    subscriber: Subject(Event),
    waiter: Option(Waiter),
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
            transport: tx,
            codec: codec,
            subscriber: subscriber,
            waiter: None,
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

/// Hand outbound text to the socket. Fire-and-forget.
///
/// There is no synchronous result: a send that fails takes the socket down,
/// which the subscriber observes as an error event. Not needing a reply is
/// what keeps the outbound path to a single hop.
@internal
pub fn send(socket: Socket, text: String) -> Nil {
  process.send(socket.subject, Send(text))
}

/// Send outbound text and block until the reply carrying `ref` arrives.
///
/// The reply is routed to this caller instead of to the subscriber. Frames
/// that arrive in the meantime still reach the subscriber — they are not
/// dropped.
@internal
pub fn send_awaiting_reply(
  socket: Socket,
  ref: String,
  text: String,
  timeout: Int,
) -> Result(Incoming, AquamarineError) {
  let reply_to = process.new_subject()
  process.send(socket.subject, SendAwaitingReply(ref, text, reply_to))

  case process.receive(reply_to, timeout) {
    Ok(event) -> event
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

    Send(text) ->
      case state.gone {
        True -> actor.continue(state)
        False ->
          case state.transport.send_text(text) {
            Ok(Nil) -> actor.continue(state)
            Error(err) -> actor.continue(lose_socket(state, err))
          }
      }

    SendAwaitingReply(ref, text, reply_to) ->
      case state.gone {
        True -> {
          process.send(reply_to, Error(error.ChannelClosed))
          actor.continue(state)
        }
        False ->
          case state.transport.send_text(text) {
            Ok(Nil) ->
              actor.continue(
                State(..state, waiter: Some(Waiter(ref, reply_to))),
              )
            Error(err) -> {
              process.send(reply_to, Error(err))
              actor.continue(lose_socket(state, err))
            }
          }
      }

    Close(reply_to) -> {
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
          process.send(waiter.reply_to, Ok(incoming))
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
      State(..state, waiter: None, gone: True)
    }
  }
}
