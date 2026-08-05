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
//// when the connector runs. Frames enqueued before the channel has sent
//// anything are buffered and released on its first outbound frame — a real
//// server says nothing until it is spoken to, and a test that scripts a join
//// reply up front means "reply to the join", not "shout it at connect time".
//// Once released, frames are delivered the instant they are enqueued.
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
  ScriptSendFailure
  ScriptCloseError(AquamarineError)
  DoSend(text: String)
  DoClose(reply_to: Subject(Result(Nil, AquamarineError)))
  Outbound(reply_to: Subject(List(String)))
  IsClosed(reply_to: Subject(Bool))
  Stop
}

type State {
  State(
    sink: Option(Subject(Frame)),
    pending: List(Frame),
    released: Bool,
    send_failures: Int,
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
      released: False,
      send_failures: 0,
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

/// Deliver a text frame after a delay, from another process.
///
/// Once the fake has released its buffer, `enqueue_text` delivers
/// *immediately* — which is too early for a reply that is supposed to answer a
/// frame the channel has not sent yet. Use this to script a server that
/// answers something already in flight.
pub fn enqueue_text_after(
  fake: FakeSocket,
  delay_ms: Int,
  text: String,
) -> Nil {
  process.spawn(fn() {
    process.sleep(delay_ms)
    enqueue_text(fake, text)
  })
  Nil
}

pub fn enqueue_binary(fake: FakeSocket, data: BitArray) -> Nil {
  process.send(fake.subject, Deliver(transport.Binary(data)))
}

pub fn enqueue_closed(fake: FakeSocket) -> Nil {
  process.send(fake.subject, Deliver(transport.Closed))
}

/// Script the next outbound send to fail, taking the connection with it.
///
/// Sending is fire-and-forget now, so a failure is not something the caller
/// hears about — it arrives as the connection closing, which is what the real
/// transport does too.
pub fn fail_next_send(fake: FakeSocket) -> Nil {
  process.send(fake.subject, ScriptSendFailure)
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
    send_text: fn(text) { process.send(fake.subject, DoSend(text)) },
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
      case state.sink, state.released {
        Some(sink), True -> {
          process.send(sink, frame)
          actor.continue(state)
        }
        // Buffered until there is a sink and the channel has spoken first.
        _, _ ->
          actor.continue(
            State(..state, pending: list.append(state.pending, [frame])),
          )
      }

    SetSink(sink) -> actor.continue(flush(State(..state, sink: Some(sink))))

    ScriptSendFailure ->
      actor.continue(State(..state, send_failures: state.send_failures + 1))

    ScriptCloseError(err) ->
      actor.continue(
        State(..state, close_errors: list.append(state.close_errors, [err])),
      )

    DoSend(text) -> {
      // A send that fails takes the connection down. That is all the socket
      // can observe now — there is no synchronous answer to give it.
      let state = case state.send_failures {
        0 -> State(..state, outbound: list.append(state.outbound, [text]))
        n -> {
          case state.sink {
            Some(sink) -> process.send(sink, transport.Closed)
            None -> Nil
          }
          State(..state, send_failures: n - 1, closed: True)
        }
      }
      // The channel has spoken; the scripted server may now answer.
      actor.continue(flush(State(..state, released: True)))
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

/// Deliver everything buffered, if there is somewhere to deliver it to.
fn flush(state: State) -> State {
  case state.sink, state.released {
    Some(sink), True -> {
      list.each(state.pending, process.send(sink, _))
      State(..state, pending: [])
    }
    _, _ -> state
  }
}
