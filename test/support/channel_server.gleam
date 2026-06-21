import beryl
import beryl/channel as bchannel
import beryl/transport/mist as mist_transport
import beryl/wire
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response
import gleam/json
import gleam/option.{Some}
import mist

pub opaque type Server {
  Server(channels: beryl.Channels)
}

pub fn start(port: Int) -> Server {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))

  let handler = fn(req) {
    mist_transport.upgrade(
      req,
      channels,
      mist_transport.default_config("/socket/websocket"),
      fn() {
        response.new(404)
        |> response.set_body(mist.Bytes(bytes_tree.new()))
      },
    )
  }

  let assert Ok(server) =
    mist.new(handler)
    |> mist.port(port)
    |> mist.start

  let _ = server
  Server(channels:)
}

pub fn register_ok(server: Server, topic: String, reply: json.Json) -> Nil {
  let channel =
    bchannel.new(fn(_topic, _payload, sock) {
      bchannel.JoinOk(reply: Some(reply), socket: sock)
    })

  let assert Ok(_) = beryl.register(server.channels, topic, channel)
  Nil
}

pub fn register_rejected(server: Server, topic: String) -> Nil {
  let channel =
    bchannel.new(fn(_topic, _payload, _sock) {
      bchannel.JoinError(reason: bchannel.error("nope"))
    })

  let assert Ok(_) = beryl.register(server.channels, topic, channel)
  Nil
}

pub fn register_echo(
  server: Server,
  topic: String,
  seen: process.Subject(String),
) -> Nil {
  let channel =
    bchannel.new(fn(_topic, _payload, sock) {
      bchannel.JoinOk(
        reply: Some(json.object([#("welcome", json.string("ok"))])),
        socket: sock,
      )
    })
    |> bchannel.with_handle_in(fn(event, _payload, sock) {
      process.send(seen, event)
      bchannel.Reply(event: "reply", payload: json.object([]), socket: sock)
    })

  let assert Ok(_) = beryl.register(server.channels, topic, channel)
  Nil
}

pub fn broadcast(
  server: Server,
  topic: String,
  event: String,
  payload: json.Json,
) -> Nil {
  beryl.broadcast(server.channels, topic, event, payload)
}

pub fn stop(_server: Server) -> Nil {
  Nil
}
