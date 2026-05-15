//// End-to-end integration tests for Aquamarine's Phoenix codec against a real
//// Beryl server running in the same VM. Verifies the full
//// phx_join -> phx_reply handshake plus a server-initiated push, plus a
//// client push -> server reply round-trip and a join rejection.

import aquamarine
import aquamarine/channel
import aquamarine/error
import aquamarine/phoenix
import beryl
import beryl/channel as bchannel
import beryl/transport/mist as mist_transport
import beryl/wire
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/response
import gleam/json
import gleam/option.{Some}
import gleam/result
import mist
import startest.{describe, it}
import startest/expect

const test_port: Int = 47_891

const test_path: String = "/socket/websocket"

pub fn integration_tests() {
  let channels = start_beryl()
  let _server = start_mist(channels)

  describe("aquamarine <-> beryl", [
    it("joins a channel and receives a server push", fn() {
      let assert Ok(ch) =
        channel.connect(
          host: "127.0.0.1",
          port: test_port,
          path: test_path,
          topic: "test:lobby",
          payload: json.object([#("hello", json.bool(True))]),
          codec: phoenix.codec(),
        )

      // Give the server a moment to register the socket as a subscriber.
      process.sleep(50)

      beryl.broadcast(
        channels,
        "test:lobby",
        "tick",
        json.object([#("n", json.int(42))]),
      )

      let assert Ok(incoming) = channel.receive(ch)
      incoming.event |> expect.to_equal("tick")
      incoming.topic |> expect.to_equal("test:lobby")
      decode_n(incoming.payload) |> expect.to_equal(Ok(42))

      let assert Ok(Nil) = channel.close(ch)
      Nil
    }),
    it("round-trips a client push through the public facade", fn() {
      let assert Ok(ch) =
        aquamarine.connect(
          host: "127.0.0.1",
          port: test_port,
          path: test_path,
          topic: "test:echo",
          payload: json.object([]),
          codec: phoenix.codec(),
        )

      let assert Ok(Nil) =
        aquamarine.push(
          ch,
          "say",
          json.object([#("body", json.string("hello"))]),
        )

      let assert Ok(incoming) = aquamarine.receive(ch)
      incoming.event |> expect.to_equal(phoenix.codec().reply_event)
      incoming.topic |> expect.to_equal("test:echo")
      decode_body(incoming.payload) |> expect.to_equal(Ok("hello"))

      let assert Ok(Nil) = aquamarine.close(ch)
      Nil
    }),
    it("surfaces a server-side join rejection", fn() {
      channel.connect(
        host: "127.0.0.1",
        port: test_port,
        path: test_path,
        topic: "test:rejected",
        payload: json.object([]),
        codec: phoenix.codec(),
      )
      |> expect.to_equal(Error(error.JoinRejected("error")))
    }),
  ])
}

fn start_beryl() -> beryl.Channels {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))

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
      bchannel.Reply(event: "reply", payload: payload, socket: sock)
    })
  let assert Ok(_) = beryl.register(channels, "test:echo", echo_channel)

  let rejected_channel =
    bchannel.new(fn(_topic, _payload, _sock) {
      bchannel.JoinError(reason: bchannel.error("nope"))
    })
  let assert Ok(_) = beryl.register(channels, "test:rejected", rejected_channel)

  channels
}

fn start_mist(channels: beryl.Channels) {
  let handler = fn(req) {
    mist_transport.upgrade(
      req,
      channels.coordinator,
      mist_transport.default_config(test_path),
      fn() {
        response.new(404)
        |> response.set_body(mist.Bytes(bytes_tree.new()))
      },
    )
  }

  let assert Ok(server) =
    mist.new(handler)
    |> mist.port(test_port)
    |> mist.start

  server
}

fn decode_n(payload) -> Result(Int, Nil) {
  let decoder = {
    use n <- decode.field("n", decode.int)
    decode.success(n)
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
