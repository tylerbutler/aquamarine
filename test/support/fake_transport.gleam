//// In-memory `transport.Transport` for unit-testing `aquamarine/channel`.
////
//// A `FakeSocket` is a small actor that lets a test:
////
//// - push inbound frames at the channel (`enqueue_*`),
//// - script send-side failures (`enqueue_send_error`),
//// - script the result of `transport.close` (`enqueue_close_error`),
//// - observe every outbound text frame that the channel hands to the
////   transport (`outbound`),
//// - observe whether the transport's `close` was called (`is_closed`).
////
//// The transport seam is push-shaped: the sink `Subject(Frame)` only arrives
//// when the connector runs. Frames enqueued before that are buffered and
//// flushed the moment the sink is known, so a test can still script its
//// inbound sequence up front — and, unlike the old pull model, can also
//// deliver a frame at any point afterwards without the channel asking.
////
//// `connector_for(fake)` returns a `Connector` to hand to
//// `channel.connect_with`.

import aquamarine/error.{type AquamarineError}
import aquamarine/transport.{type Frame, type Transport}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor

pub opaque type FakeSocket {
  FakeSocket(subject: Subject(Message))
}

pub opaque type Message {
  Deliver(Frame)
  SetSink(Subject(Frame))
  ScriptSendError(AquamarineError)
  ScriptCloseError(AquamarineError)
  DoSend(text: String, reply_to: Subject(Result(Nil, AquamarineError)))
  DoClose(reply_to: Subject(Result(Nil, AquamarineError)))
  Outbound(reply_to: Subject(List(String)))
  IsClosed(reply_to: Subject(Bool))
  Stop
}

type State {
  State(
    sink: Option(Subject(Frame)),
    pending: List(Frame),
    send_errors: List(AquamarineError),
    close_errors: List(AquamarineError),
    outbound: List(String),
    closed: Bool,
  )
}

pub fn start() -> FakeSocket {
  let assert Ok(started) =
    actor.new(State(
      sink: None,
      pending: [],
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
  process.send(fake.subject, Deliver(transport.Text(text)))
}

pub fn enqueue_binary(fake: FakeSocket, data: BitArray) -> Nil {
  process.send(fake.subject, Deliver(transport.Binary(data)))
}

pub fn enqueue_closed(fake: FakeSocket) -> Nil {
  process.send(fake.subject, Deliver(transport.Closed))
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
    close: fn() { process.call(fake.subject, 1000, DoClose) },
  )
}

pub fn connector_for(fake: FakeSocket) -> transport.Connector {
  fn(sink) {
    process.send(fake.subject, SetSink(sink))
    Ok(transport(fake))
  }
}

pub fn failing_connector(err: AquamarineError) -> transport.Connector {
  fn(_sink) { Error(err) }
}

fn handle(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    Deliver(frame) ->
      case state.sink {
        Some(sink) -> {
          process.send(sink, frame)
          actor.continue(state)
        }
        // Buffered until the connector hands us a sink.
        None ->
          actor.continue(
            State(..state, pending: list.append(state.pending, [frame])),
          )
      }

    SetSink(sink) -> {
      list.each(state.pending, process.send(sink, _))
      actor.continue(State(..state, sink: Some(sink), pending: []))
    }

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
