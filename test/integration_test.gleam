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

const test_path: String = "/socket/websocket"

const unused_port: Int = 48_100

type IntegrationEvent {
  IntegrationJoined(String)
  IntegrationMessage(Incoming)
  IntegrationError(error.AquamarineError)
  IntegrationClosed
}

type IntegrationState {
  IntegrationState(events: process.Subject(IntegrationEvent))
}

pub fn integration_join_callback_test() {
  let events = process.new_subject()
  let server = channel_server.start()
  let port = channel_server.port(server)
  channel_server.register_ok(
    server,
    "test:lobby",
    json.object([#("welcome", json.string("ok"))]),
  )

  let assert Ok(ch) =
    aquamarine.connect(
      aquamarine.config(
        host: "127.0.0.1",
        port: port,
        path: test_path,
        topic: "test:lobby",
        payload: json.object([]),
        codec: phoenix.codec(),
      ),
      integration_handlers(),
      IntegrationState(events),
    )

  process.receive(events, 1000)
  |> should.equal(Ok(IntegrationJoined("ok")))

  let assert Ok(Nil) = aquamarine.close(ch)
  channel_server.stop(server)
}

pub fn integration_server_push_callback_test() {
  let events = process.new_subject()
  let server = channel_server.start()
  let port = channel_server.port(server)
  channel_server.register_ok(
    server,
    "test:lobby",
    json.object([#("welcome", json.string("ok"))]),
  )

  let assert Ok(ch) =
    aquamarine.connect(
      aquamarine.config(
        host: "127.0.0.1",
        port: port,
        path: test_path,
        topic: "test:lobby",
        payload: json.object([]),
        codec: phoenix.codec(),
      ),
      integration_handlers(),
      IntegrationState(events),
    )

  process.receive(events, 1000)
  |> should.equal(Ok(IntegrationJoined("ok")))

  channel_server.broadcast(
    server,
    "test:lobby",
    "tick",
    json.object([#("n", json.int(42))]),
  )

  let assert Ok(IntegrationMessage(incoming)) = process.receive(events, 1000)
  incoming.event |> should.equal("tick")
  incoming.topic |> should.equal("test:lobby")

  let decoder = {
    use n <- decode.field("n", decode.int)
    decode.success(n)
  }
  decode.run(incoming.payload, decoder)
  |> should.equal(Ok(42))

  let assert Ok(Nil) = aquamarine.close(ch)
  channel_server.stop(server)
}

pub fn integration_client_push_reply_callback_test() {
  let events = process.new_subject()
  let seen = process.new_subject()
  let server = channel_server.start()
  let port = channel_server.port(server)
  channel_server.register_echo(server, "test:echo", seen)

  let assert Ok(ch) =
    aquamarine.connect(
      aquamarine.config(
        host: "127.0.0.1",
        port: port,
        path: test_path,
        topic: "test:echo",
        payload: json.object([]),
        codec: phoenix.codec(),
      ),
      integration_handlers(),
      IntegrationState(events),
    )

  process.receive(events, 1000)
  |> should.equal(Ok(IntegrationJoined("ok")))

  let assert Ok(Nil) =
    aquamarine.push(ch, "say", json.object([#("body", json.string("hello"))]))

  process.receive(seen, 1000)
  |> should.equal(Ok("say"))

  let assert Ok(IntegrationMessage(incoming)) = process.receive(events, 1000)
  incoming.event |> should.equal(phoenix.codec().reply_event)
  incoming.topic |> should.equal("test:echo")

  let reply_decoder = {
    use status <- decode.field("status", decode.string)
    use response <- decode.field("response", decode.dynamic)
    decode.success(#(status, response))
  }
  let assert Ok(#(status, response)) =
    decode.run(incoming.payload, reply_decoder)
  status |> should.equal("ok")

  let response_decoder = {
    use body <- decode.field("body", decode.string)
    decode.success(body)
  }
  decode.run(response, response_decoder)
  |> should.equal(Ok("hello"))

  let assert Ok(Nil) = aquamarine.close(ch)
  channel_server.stop(server)
}

pub fn integration_join_rejection_test() {
  let server = channel_server.start()
  let port = channel_server.port(server)
  channel_server.register_rejected(server, "test:rejected")

  aquamarine.connect(
    aquamarine.config(
      host: "127.0.0.1",
      port: port,
      path: test_path,
      topic: "test:rejected",
      payload: json.object([]),
      codec: phoenix.codec(),
    ),
    integration_handlers(),
    IntegrationState(process.new_subject()),
  )
  |> should.equal(Error(error.JoinRejected("error")))

  channel_server.stop(server)
}

pub fn integration_startup_transport_errors_test() {
  let server = channel_server.start()
  let port = channel_server.port(server)

  case
    aquamarine.connect(
      aquamarine.config(
        host: "127.0.0.1",
        port: port,
        path: "/wrong",
        topic: "test:lobby",
        payload: json.object([]),
        codec: phoenix.codec(),
      ),
      integration_handlers(),
      IntegrationState(process.new_subject()),
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
      integration_handlers(),
      IntegrationState(process.new_subject()),
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

fn integration_handlers() {
  aquamarine.handlers(
    on_joined: fn(state: IntegrationState, payload) {
      let decoder = {
        use welcome <- decode.field("welcome", decode.string)
        decode.success(welcome)
      }
      let assert Ok(value) = decode.run(payload, decoder)
      process.send(state.events, IntegrationJoined(value))
      aquamarine.continue(state)
    },
    on_message: fn(state: IntegrationState, incoming: Incoming) {
      process.send(state.events, IntegrationMessage(incoming))
      aquamarine.continue(state)
    },
    on_error: fn(state: IntegrationState, err) {
      process.send(state.events, IntegrationError(err))
      aquamarine.continue(state)
    },
    on_closed: fn(state: IntegrationState) {
      process.send(state.events, IntegrationClosed)
      aquamarine.continue(state)
    },
  )
}
