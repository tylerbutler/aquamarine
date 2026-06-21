//// Integration coverage for the public callback runtime against a real Beryl
//// server running in the same VM.

import aquamarine
import aquamarine/codec.{type Incoming}
import aquamarine/error
import aquamarine/phoenix
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleeunit/should
import support/channel_server

const test_port: Int = 47_895

const test_path: String = "/socket/websocket"

const unused_port: Int = 47_896

type Event {
  Joined(String)
  Message(String)
  ErrorSeen(error.AquamarineError)
  Closed
}

type State {
  State(events: process.Subject(Event))
}

pub fn integration_tests_test() {
  let events = process.new_subject()
  let echo_events = process.new_subject()
  let seen = process.new_subject()
  let server = channel_server.start(test_port)
  channel_server.register_ok(
    server,
    "test:lobby",
    json.object([#("welcome", json.string("ok"))]),
  )
  channel_server.register_rejected(server, "test:rejected")
  channel_server.register_echo(server, "test:echo", seen)

  let assert Ok(ch) =
    aquamarine.connect(
      aquamarine.config(
        host: "127.0.0.1",
        port: test_port,
        path: test_path,
        topic: "test:lobby",
        payload: json.object([]),
        codec: phoenix.codec(),
      ),
      handlers(),
      State(events),
    )

  process.receive(events, 1000)
  |> should.equal(Ok(Joined("ok")))

  let assert Ok(Nil) = aquamarine.close(ch)

  let assert Ok(ch) =
    aquamarine.connect(
      aquamarine.config(
        host: "127.0.0.1",
        port: test_port,
        path: test_path,
        topic: "test:echo",
        payload: json.object([]),
        codec: phoenix.codec(),
      ),
      handlers(),
      State(echo_events),
    )

  process.receive(echo_events, 1000)
  |> should.equal(Ok(Joined("ok")))

  let assert Ok(Nil) =
    aquamarine.push(ch, "say", json.object([#("body", json.string("hello"))]))
  process.receive(seen, 1000)
  |> should.equal(Ok("say"))
  process.receive(echo_events, 1000)
  |> should.equal(Ok(Message(phoenix.codec().reply_event)))

  let assert Ok(Nil) = aquamarine.close(ch)

  aquamarine.connect(
    aquamarine.config(
      host: "127.0.0.1",
      port: test_port,
      path: test_path,
      topic: "test:rejected",
      payload: json.object([]),
      codec: phoenix.codec(),
    ),
    handlers(),
    State(process.new_subject()),
  )
  |> should.equal(Error(error.JoinRejected("error")))

  case
    aquamarine.connect(
      aquamarine.config(
        host: "127.0.0.1",
        port: test_port,
        path: "/wrong",
        topic: "test:lobby",
        payload: json.object([]),
        codec: phoenix.codec(),
      ),
      handlers(),
      State(process.new_subject()),
    )
  {
    Error(error.Transport(error.HandshakeFailed(_))) -> Nil
    other ->
      other
      |> should.equal(
        Error(error.Transport(error.HandshakeFailed("unexpected"))),
      )
  }

  case
    aquamarine.connect(
      aquamarine.config(
        host: "127.0.0.1",
        port: unused_port,
        path: test_path,
        topic: "test:lobby",
        payload: json.object([]),
        codec: phoenix.codec(),
      ),
      handlers(),
      State(process.new_subject()),
    )
  {
    Error(error.Transport(error.SocketConnectionFailed(_))) -> Nil
    other ->
      other
      |> should.equal(
        Error(error.Transport(error.SocketConnectionFailed("unexpected"))),
      )
  }

  channel_server.stop(server)
}

fn handlers() {
  aquamarine.handlers(
    on_joined: fn(state: State, payload) {
      let decoder = {
        use welcome <- decode.field("welcome", decode.string)
        decode.success(welcome)
      }
      let assert Ok(value) = decode.run(payload, decoder)
      process.send(state.events, Joined(value))
      aquamarine.continue(state)
    },
    on_message: fn(state: State, incoming: Incoming) {
      process.send(state.events, Message(incoming.event))
      aquamarine.continue(state)
    },
    on_error: fn(state: State, err) {
      process.send(state.events, ErrorSeen(err))
      aquamarine.continue(state)
    },
    on_closed: fn(state: State) {
      process.send(state.events, Closed)
      aquamarine.continue(state)
    },
  )
}
