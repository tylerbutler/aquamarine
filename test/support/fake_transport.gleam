//// In-memory `transport.Transport` for unit-testing `aquamarine/channel`.
////
//// A `FakeSocket` is a small actor that lets a test:
////
//// - script the sequence of inbound results that `transport.receive` will
////   return (`enqueue_*`),
//// - script send-side failures (`enqueue_send_error`),
//// - script the result of `transport.close` (`enqueue_close_error`),
//// - observe every outbound text frame that the channel hands to the
////   transport (`outbound`),
//// - observe whether the transport's `close` was called (`is_closed`).
////
//// `transport(fake)` returns a `Transport` value bound to this fake. Pass it
//// to `channel.connect_with` via a `Connector` (see `connector_for/1`).

import aquamarine/error.{type AquamarineError}
import aquamarine/transport.{type Frame, type Transport}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor

pub opaque type FakeSocket {
  FakeSocket(subject: Subject(Message))
}

pub opaque type Message {
  ScriptReceive(Result(Frame, AquamarineError))
  ScriptSendError(AquamarineError)
  ScriptCloseError(AquamarineError)
  DoSend(text: String, reply_to: Subject(Result(Nil, AquamarineError)))
  DoReceive(reply_to: Subject(Result(Frame, AquamarineError)))
  DoClose(reply_to: Subject(Result(Nil, AquamarineError)))
  Outbound(reply_to: Subject(List(String)))
  IsClosed(reply_to: Subject(Bool))
  Stop
}

type State {
  State(
    inbound: List(Result(Frame, AquamarineError)),
    send_errors: List(AquamarineError),
    close_errors: List(AquamarineError),
    outbound: List(String),
    closed: Bool,
  )
}

pub fn start() -> FakeSocket {
  let assert Ok(started) =
    actor.new(State(
      inbound: [],
      send_errors: [],
      close_errors: [],
      outbound: [],
      closed: False,
    ))
    |> actor.on_message(handle)
    |> actor.start
  FakeSocket(subject: started.data)
}

pub fn shutdown(fake: FakeSocket) -> Nil {
  process.send(fake.subject, Stop)
}

pub fn enqueue_text(fake: FakeSocket, text: String) -> Nil {
  process.send(fake.subject, ScriptReceive(Ok(transport.Text(text))))
}

pub fn enqueue_binary(fake: FakeSocket, data: BitArray) -> Nil {
  process.send(fake.subject, ScriptReceive(Ok(transport.Binary(data))))
}

pub fn enqueue_closed(fake: FakeSocket) -> Nil {
  process.send(fake.subject, ScriptReceive(Ok(transport.Closed)))
}

pub fn enqueue_receive_error(fake: FakeSocket, err: AquamarineError) -> Nil {
  process.send(fake.subject, ScriptReceive(Error(err)))
}

pub fn enqueue_send_error(fake: FakeSocket, err: AquamarineError) -> Nil {
  process.send(fake.subject, ScriptSendError(err))
}

pub fn enqueue_close_error(fake: FakeSocket, err: AquamarineError) -> Nil {
  process.send(fake.subject, ScriptCloseError(err))
}

pub fn outbound(fake: FakeSocket) -> List(String) {
  process.call(fake.subject, 1000, Outbound)
}

pub fn is_closed(fake: FakeSocket) -> Bool {
  process.call(fake.subject, 1000, IsClosed)
}

pub fn transport(fake: FakeSocket) -> Transport {
  transport.Transport(
    send_text: fn(text) { process.call(fake.subject, 1000, DoSend(text, _)) },
    receive: fn() { process.call(fake.subject, 5000, DoReceive) },
    close: fn() { process.call(fake.subject, 1000, DoClose) },
  )
}

pub fn connector_for(fake: FakeSocket) -> transport.Connector {
  fn() { Ok(transport(fake)) }
}

pub fn failing_connector(err: AquamarineError) -> transport.Connector {
  fn() { Error(err) }
}

fn handle(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    ScriptReceive(item) ->
      actor.continue(
        State(..state, inbound: list.append(state.inbound, [item])),
      )

    ScriptSendError(err) ->
      actor.continue(
        State(..state, send_errors: list.append(state.send_errors, [err])),
      )

    ScriptCloseError(err) ->
      actor.continue(
        State(..state, close_errors: list.append(state.close_errors, [err])),
      )

    DoSend(text, reply_to) ->
      case state.send_errors {
        [err, ..rest] -> {
          process.send(reply_to, Error(err))
          actor.continue(State(..state, send_errors: rest))
        }
        [] -> {
          process.send(reply_to, Ok(Nil))
          actor.continue(
            State(..state, outbound: list.append(state.outbound, [text])),
          )
        }
      }

    DoReceive(reply_to) ->
      case state.inbound {
        [item, ..rest] -> {
          process.send(reply_to, item)
          actor.continue(State(..state, inbound: rest))
        }
        [] -> {
          process.send(
            reply_to,
            Error(error.Transport(error.SocketReceiveFailed("timeout"))),
          )
          actor.continue(state)
        }
      }

    DoClose(reply_to) ->
      case state.close_errors {
        [err, ..rest] -> {
          process.send(reply_to, Error(err))
          actor.continue(State(..state, closed: True, close_errors: rest))
        }
        [] -> {
          process.send(reply_to, Ok(Nil))
          actor.continue(State(..state, closed: True))
        }
      }

    Outbound(reply_to) -> {
      process.send(reply_to, state.outbound)
      actor.continue(state)
    }

    IsClosed(reply_to) -> {
      process.send(reply_to, state.closed)
      actor.continue(state)
    }

    Stop -> actor.stop()
  }
}
