//// End-to-end integration tests for Aquamarine's Phoenix codec against a real
//// Beryl server running in the same VM. Verifies the full
//// phx_join -> phx_reply handshake plus a server-initiated push, plus a
//// client push -> server reply round-trip and a join rejection.

import aquamarine
import aquamarine/channel
import aquamarine/error
import aquamarine/phoenix
import aquamarine/socket
import beryl
import beryl/channel as bchannel
import beryl/supervisor
import beryl/wire
import beryl_mist as mist_transport
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/response
import gleam/json
import gleam/option.{Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/result
import mist

const test_path: String = "/socket/websocket"

/// A running beryl instance plus the port its mist listener bound to.
type TestServer {
  TestServer(channels: beryl.Channels, port: Int)
}

pub fn joins_a_channel_and_receives_a_server_push_test() {
  let server = start_server()

  let assert Ok(ch) =
    channel.connect(
      host: "127.0.0.1",
      port: server.port,
      path: test_path,
      topic: "test:lobby",
      payload: json.object([#("hello", json.bool(True))]),
      codec: phoenix.codec(),
    )

  // Give the server a moment to register the socket as a subscriber.
  process.sleep(50)

  beryl.broadcast(
    server.channels,
    "test:lobby",
    "tick",
    json.object([#("n", json.int(42))]),
  )

  let assert Ok(incoming) = channel.receive(ch)
  assert incoming.event == "tick"
  assert incoming.topic == "test:lobby"
  assert decode_n(incoming.payload) == Ok(42)

  let assert Ok(Nil) = channel.close(ch)
}

pub fn round_trips_a_client_push_through_the_public_facade_test() {
  let server = start_server()

  let assert Ok(ch) =
    aquamarine.connect(
      host: "127.0.0.1",
      port: server.port,
      path: test_path,
      topic: "test:echo",
      payload: json.object([]),
      codec: phoenix.codec(),
    )

  aquamarine.push(ch, "say", json.object([#("body", json.string("hello"))]))

  let assert Ok(incoming) = aquamarine.receive(ch)
  assert incoming.event == phoenix.codec().reply_event
  assert incoming.topic == "test:echo"
  assert decode_body(incoming.payload) == Ok("hello")

  let assert Ok(Nil) = aquamarine.close(ch)
}

pub fn awaits_a_correlated_reply_through_the_public_facade_test() {
  let server = start_server()

  let assert Ok(ch) =
    aquamarine.connect(
      host: "127.0.0.1",
      port: server.port,
      path: test_path,
      topic: "test:echo",
      payload: json.object([]),
      codec: phoenix.codec(),
    )

  let assert Ok(incoming) =
    aquamarine.push_and_await_reply(
      ch,
      "say",
      json.object([#("body", json.string("correlated"))]),
      5000,
    )
  assert incoming.event == phoenix.codec().reply_event
  assert decode_body(incoming.payload) == Ok("correlated")

  let assert Ok(Nil) = aquamarine.close(ch)
}

/// #8: a caller can assert the live accepted join payload without inspecting
/// raw frames or fabricating one. `test:lobby` accepts with `{welcome: true}`.
pub fn exposes_the_live_accepted_join_reply_test() {
  let server = start_server()

  let assert Ok(ch) =
    aquamarine.connect(
      host: "127.0.0.1",
      port: server.port,
      path: test_path,
      topic: "test:lobby",
      payload: json.object([]),
      codec: phoenix.codec(),
    )

  let reply = aquamarine.join_reply(ch)
  assert reply.topic == "test:lobby"
  assert reply.event == phoenix.codec().reply_event
  assert decode_welcome(reply.payload) == Ok(True)

  let assert Ok(Nil) = aquamarine.close(ch)
}

/// One connection, two topics, against a real server. Each channel sees only
/// its own traffic, and leaving one leaves the other working.
pub fn serves_two_topics_over_one_socket_test() {
  let server = start_server()

  let assert Ok(sock) =
    socket.connect(
      host: "127.0.0.1",
      port: server.port,
      path: test_path,
      codec: phoenix.codec(),
    )

  let assert Ok(lobby) = channel.join(sock, "test:lobby", json.object([]), 5000)
  let assert Ok(echoes) = channel.join(sock, "test:echo", json.object([]), 5000)

  // A broadcast to lobby must not appear on echo.
  process.sleep(50)
  beryl.broadcast(
    server.channels,
    "test:lobby",
    "tick",
    json.object([#("n", json.int(7))]),
  )

  let assert Ok(incoming) = channel.receive(lobby)
  assert incoming.topic == "test:lobby"
  assert incoming.event == "tick"

  // The echo topic's own round-trip still works on the same connection.
  let assert Ok(reply) =
    channel.push_and_await_reply(
      echoes,
      "say",
      json.object([#("body", json.string("multiplexed"))]),
      5000,
    )
  assert reply.topic == "test:echo"
  assert decode_body(reply.payload) == Ok("multiplexed")

  // Leaving lobby leaves the echo channel — and the connection — alone.
  let assert Ok(Nil) = channel.leave(lobby)
  let assert Ok(reply2) =
    channel.push_and_await_reply(
      echoes,
      "say",
      json.object([#("body", json.string("after_leave"))]),
      5000,
    )
  assert decode_body(reply2.payload) == Ok("after_leave")

  let assert Ok(Nil) = socket.close(sock)
}

/// Joining the same topic twice on one socket is an error, not a takeover.
pub fn rejects_a_duplicate_join_on_one_socket_test() {
  let server = start_server()

  let assert Ok(sock) =
    socket.connect(
      host: "127.0.0.1",
      port: server.port,
      path: test_path,
      codec: phoenix.codec(),
    )

  let assert Ok(_) = channel.join(sock, "test:lobby", json.object([]), 5000)
  assert channel.join(sock, "test:lobby", json.object([]), 5000)
    == Error(error.AlreadyJoined("test:lobby"))

  let assert Ok(Nil) = socket.close(sock)
}

pub fn surfaces_a_server_side_join_rejection_test() {
  let server = start_server()

  assert channel.connect(
      host: "127.0.0.1",
      port: server.port,
      path: test_path,
      topic: "test:rejected",
      payload: json.object([]),
      codec: phoenix.codec(),
    )
    == Error(error.JoinRejected("error"))
}

/// Stand up a beryl instance with the test channels registered and a mist
/// listener bound to an ephemeral port.
fn start_server() -> TestServer {
  let assert Ok(channels) = start_supervised(beryl.config(wire.phoenix_codec()))
  register_channels(channels)
  TestServer(channels, start_mist(channels))
}

/// Start a supervised channel system for tests.
///
/// beryl exposes no public unsupervised start, so tests stand up a real
/// supervision tree the way an application would.
fn start_supervised(
  config: beryl.Config,
) -> Result(beryl.Channels, actor.StartError) {
  let supervised = supervisor.config(config)
  use _root <- result.map(
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(supervisor.start(supervised))
    |> static_supervisor.start(),
  )
  supervisor.channels(supervised)
}

fn register_channels(channels: beryl.Channels) -> Nil {
  let lobby_channel =
    bchannel.new(fn(_topic, _payload, sock) {
      bchannel.JoinOk(
        reply: Some(json.object([#("welcome", json.bool(True))])),
        socket: sock,
      )
    })
  let assert Ok(_) = beryl.register(channels, "test:lobby", lobby_channel)

  let echo_channel =
    bchannel.new(fn(_topic, _payload, sock) {
      bchannel.JoinOk(reply: Some(json.object([])), socket: sock)
    })
    |> bchannel.with_handle_in(fn(_event, payload, sock) {
      let body =
        bchannel.decode_payload(payload, {
          use body <- decode.field("body", decode.string)
          decode.success(body)
        })
        |> result.unwrap("")
      bchannel.Reply(
        event: "reply",
        payload: json.object([#("body", json.string(body))]),
        socket: sock,
      )
    })
  let assert Ok(_) = beryl.register(channels, "test:echo", echo_channel)

  let rejected_channel =
    bchannel.new(fn(_topic, _payload, _sock) {
      bchannel.JoinError(reason: bchannel.error("nope"))
    })
  let assert Ok(_) = beryl.register(channels, "test:rejected", rejected_channel)

  Nil
}

/// Start a mist listener on an ephemeral port and return the bound port.
fn start_mist(channels: beryl.Channels) -> Int {
  let port_subject = process.new_subject()

  let handler = fn(req) {
    mist_transport.upgrade(
      req,
      channels,
      mist_transport.default_config(test_path),
      fn() {
        response.new(404)
        |> response.set_body(mist.Bytes(bytes_tree.new()))
      },
    )
  }

  let assert Ok(_server) =
    mist.new(handler)
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _scheme, _ip_address) {
      process.send(port_subject, port)
    })
    |> mist.start

  let assert Ok(port) = process.receive(port_subject, 1000)
  port
}

fn decode_n(payload) -> Result(Int, Nil) {
  let decoder = {
    use n <- decode.field("n", decode.int)
    decode.success(n)
  }
  decode.run(payload, decoder)
  |> result.map_error(fn(_) { Nil })
}

fn decode_welcome(payload) -> Result(Bool, Nil) {
  let decoder = {
    use welcome <- decode.subfield(["response", "welcome"], decode.bool)
    decode.success(welcome)
  }
  decode.run(payload, decoder)
  |> result.map_error(fn(_) { Nil })
}

fn decode_body(payload) -> Result(String, Nil) {
  // The server replies with `{"status": "ok", "response": <our payload>}`.
  let decoder = {
    use body <- decode.subfield(["response", "body"], decode.string)
    decode.success(body)
  }
  decode.run(payload, decoder)
  |> result.map_error(fn(_) { Nil })
}
