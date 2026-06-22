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
import mist

pub opaque type Server {
  Server(channels: beryl.Channels, pid: process.Pid, port: Int)
}

pub fn start() -> Server {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let port_subject = process.new_subject()

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
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _scheme, _ip_address) {
      process.send(port_subject, port)
    })
    |> mist.start

  let assert Ok(port) = process.receive(port_subject, 1000)
  Server(channels: channels, pid: server.pid, port: port)
}

pub fn port(server: Server) -> Int {
  server.port
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
    |> bchannel.with_handle_in(fn(event, payload, sock) {
      process.send(seen, event)
      let body_decoder = {
        use body <- decode.field("body", decode.string)
        decode.success(body)
      }
      let reply_payload = case decode.run(payload, body_decoder) {
        Ok(body) -> json.object([#("body", json.string(body))])
        Error(_) -> json.object([])
      }
      bchannel.Reply(event: "reply", payload: reply_payload, socket: sock)
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

pub fn stop(server: Server) -> Nil {
  process.unlink(server.pid)
  process.send_exit(server.pid)

  let assert Ok(coordinator_pid) =
    process.subject_owner(server.channels.coordinator)
  process.unlink(coordinator_pid)
  process.send_exit(coordinator_pid)

  Nil
}

pub fn crash(server: Server) -> Nil {
  stop(server)
}
