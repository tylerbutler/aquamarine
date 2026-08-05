//// End-to-end integration tests for Aquamarine's Phoenix codec against a real
//// Beryl server running in the same VM. Verifies the full
//// phx_join -> phx_reply handshake plus a server-initiated push, plus a
//// client push -> server reply round-trip and a join rejection.

import aquamarine
import aquamarine/backoff
import aquamarine/channel
import aquamarine/error
import aquamarine/phoenix
import aquamarine/socket
import aquamarine/transport
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
import gleam/string
import mist

const test_path: String = "/socket/websocket"

/// A running beryl instance plus the port its mist listener bound to, and the
/// listener's own supervisor so a test can take the server away.
type TestServer {
  TestServer(channels: beryl.Channels, port: Int, listener: process.Pid)
}

pub fn joins_a_channel_and_receives_a_server_push_test() {
  let server = start_server()

  let assert Ok(ch) =
    channel.connect(
      scheme: transport.Ws,
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

  let assert Ok(incoming) = channel.receive(ch, 500)
  assert incoming.event == "tick"
  assert incoming.topic == "test:lobby"
  assert decode_n(incoming.payload) == Ok(42)

  let assert Ok(Nil) = channel.close(ch)
}

pub fn round_trips_a_client_push_through_the_public_facade_test() {
  let server = start_server()

  let assert Ok(ch) =
    aquamarine.connect(
      scheme: transport.Ws,
      host: "127.0.0.1",
      port: server.port,
      path: test_path,
      topic: "test:echo",
      payload: json.object([]),
      codec: phoenix.codec(),
    )

  aquamarine.push(ch, "say", json.object([#("body", json.string("hello"))]))

  let assert Ok(incoming) = aquamarine.receive(ch, 5000)
  assert incoming.event == phoenix.codec().reply_event
  assert incoming.topic == "test:echo"
  assert decode_body(incoming.payload) == Ok("hello")

  let assert Ok(Nil) = aquamarine.close(ch)
}

pub fn awaits_a_correlated_reply_through_the_public_facade_test() {
  let server = start_server()

  let assert Ok(ch) =
    aquamarine.connect(
      scheme: transport.Ws,
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
      scheme: transport.Ws,
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
      scheme: transport.Ws,
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

  let assert Ok(incoming) = channel.receive(lobby, 500)
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
      scheme: transport.Ws,
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

/// A payload far larger than one TCP segment, echoed back and compared byte
/// for byte. Reassembling a message that arrives across many reads is the
/// specific area where the previous transport candidate fell down, so it is
/// worth asserting against a real server rather than trusting the claim.
///
/// This covers multi-*packet* reassembly. WebSocket continuation frames are a
/// separate mechanism, and whether one is exercised here depends on Mist's
/// choice to fragment, which we do not control.
pub fn round_trips_a_payload_larger_than_one_read_test() {
  let server = start_server()

  let assert Ok(ch) =
    aquamarine.connect(
      scheme: transport.Ws,
      host: "127.0.0.1",
      port: server.port,
      path: test_path,
      topic: "test:echo",
      payload: json.object([]),
      codec: phoenix.codec(),
    )

  let big = string.repeat("aquamarine-0123456789-", 8000)

  let assert Ok(incoming) =
    aquamarine.push_and_await_reply(
      ch,
      "say",
      json.object([#("body", json.string(big))]),
      10_000,
    )
  assert decode_body(incoming.payload) == Ok(big)

  let assert Ok(Nil) = aquamarine.close(ch)
}

/// The payoff for the whole epic, against a real server: kill it mid-session,
/// put a fresh one back on the same port, and the client finds its way home
/// with its channel handle still valid.
pub fn reconnects_and_rejoins_after_the_server_goes_away_test() {
  let server = start_server()
  let port = server.port

  let assert Ok(sock) =
    socket.start(
      socket.config(
        scheme: transport.Ws,
        host: "127.0.0.1",
        port: port,
        path: test_path,
        codec: phoenix.codec(),
      )
      // Fast enough to watch, still a real schedule.
      |> socket.with_backoff(
        backoff.default()
        |> backoff.with_initial_ms(50)
        |> backoff.with_max_ms(200),
      ),
    )
  let status = process.new_subject()
  socket.watch(sock, status)

  let assert Ok(lobby) = channel.join(sock, "test:lobby", json.object([]), 5000)

  stop_server(server)
  let assert Ok(socket.Disconnected(_)) = process.receive(status, 5000)

  // A fresh server takes the old one's place.
  let replacement = start_server_on(port)
  let assert Ok(socket.Rejoined("test:lobby")) = await_rejoin(status, 15_000)

  // The `Channel` from before the drop still works — same actor, same subject.
  process.sleep(100)
  beryl.broadcast(
    replacement.channels,
    "test:lobby",
    "tick",
    json.object([#("n", json.int(1))]),
  )
  let assert Ok(incoming) = channel.receive(lobby, 5000)
  assert incoming.event == "tick"
  assert incoming.topic == "test:lobby"

  let assert Ok(Nil) = socket.close(sock)
}

fn await_rejoin(
  status: process.Subject(socket.Status),
  timeout: Int,
) -> Result(socket.Status, Nil) {
  case process.receive(status, timeout) {
    Ok(socket.Rejoined(topic)) -> Ok(socket.Rejoined(topic))
    Ok(_) -> await_rejoin(status, timeout)
    Error(Nil) -> Error(Nil)
  }
}

pub fn surfaces_a_server_side_join_rejection_test() {
  let server = start_server()

  assert channel.connect(
      scheme: transport.Ws,
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
  start_server_on(0)
}

/// Same, on a specific port — so a test can put a fresh server back where the
/// old one was and watch a client find its way home.
fn start_server_on(port: Int) -> TestServer {
  let assert Ok(channels) = start_supervised(beryl.config(wire.phoenix_codec()))
  register_channels(channels)
  let #(bound, listener) = start_mist(channels, port)
  TestServer(channels, bound, listener)
}

/// Take the listener down hard, taking every live connection with it.
fn stop_server(server: TestServer) -> Nil {
  process.unlink(server.listener)
  process.kill(server.listener)
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
fn start_mist(channels: beryl.Channels, port: Int) -> #(Int, process.Pid) {
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

  let assert Ok(server) =
    mist.new(handler)
    |> mist.port(port)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _scheme, _ip_address) {
      process.send(port_subject, port)
    })
    |> mist.start

  let assert Ok(bound) = process.receive(port_subject, 1000)
  #(bound, server.pid)
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
