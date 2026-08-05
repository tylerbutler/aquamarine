//// Internal WebSocket transport seam.
////
//// `aquamarine/channel` does not call Gluegun directly; it operates on a
//// `Transport` value that exposes the two outbound operations the channel
//// lifecycle needs: `send_text` and `close`.
////
//// Inbound frames are *pushed*: a `Connector` is handed a sink
//// `process.Subject(Frame)` at connect time and delivers every inbound frame
//// into it, including the terminal [`Closed`](#Frame). Nothing pulls.
////
//// Production code uses [`gluegun_connector`](#gluegun_connector) to build
//// a Gluegun-backed `Transport`. Tests can build an in-memory `Transport`
//// to script inbound frames and observe outbound frames deterministically.
////
//// The whole module is `@internal` — it is reachable from tests in this
//// repo but not part of the public Aquamarine API surface.

import aquamarine/error.{type AquamarineError}
import gleam/erlang/process.{type Subject}
import gleam/result
import gluegun/error as gluegun_error
import gluegun/message
import gluegun/websocket

/// How long to wait for the reader process to report the result of its
/// connect attempt. Gluegun applies its own 5s timeout to each step of the
/// handshake, so this only has to be generous enough not to pre-empt it.
const connect_timeout_ms: Int = 30_000

/// Application-level frame surfaced to the channel layer.
///
/// Gluegun's `receive_app_frame` already answers pings and skips pongs, so
/// the channel only ever needs to distinguish text, binary, and "the socket
/// is gone" frames.
@internal
pub type Frame {
  Text(text: String)
  Binary(data: BitArray)
  Closed
}

/// Transport bound to a single, already-open WebSocket socket.
///
/// Outbound only. Inbound frames arrive on the sink subject the `Connector`
/// was given.
@internal
pub type Transport {
  Transport(
    send_text: fn(String) -> Result(Nil, AquamarineError),
    close: fn() -> Result(Nil, AquamarineError),
  )
}

/// A function that opens a transport. `channel.connect_with` takes one of
/// these so production and test paths share the same connect-time error
/// handling.
///
/// Takes the sink that inbound frames should be delivered to.
@internal
pub type Connector =
  fn(Subject(Frame)) -> Result(Transport, AquamarineError)

/// Build a Gluegun-backed connector for the given host/port/path.
@internal
pub fn gluegun_connector(
  host host: String,
  port port: Int,
  path path: String,
) -> Connector {
  fn(sink: Subject(Frame)) {
    let ready = process.new_subject()
    let _ = process.spawn(fn() { reader(host, port, path, sink, ready) })

    case process.receive(ready, connect_timeout_ms) {
      Ok(Ok(socket)) -> Ok(from_socket(socket))
      Ok(Error(err)) -> Error(err)
      Error(Nil) -> Error(error.Transport(error.Timeout))
    }
  }
}

/// Temporary reader-process shim. See the epic at
/// <https://github.com/tylerbutler/aquamarine/issues/13>.
///
/// Gluegun's read side is pull-shaped, and Gun delivers frames to the process
/// that *owns* the connection — so the only way to push frames into a sink is
/// to open the connection inside a dedicated process and forward from there.
/// The socket value is handed back to the caller over `ready` because sending
/// and closing are safe from any process; only receiving is owner-bound.
///
/// This shim is scaffolding. It is deleted by the Collie swap in Phase 3
/// (<https://github.com/tylerbutler/aquamarine/issues/22>), where the client
/// is push-shaped natively and no forwarding process is needed.
fn reader(
  host: String,
  port: Int,
  path: String,
  sink: Subject(Frame),
  ready: Subject(Result(websocket.Socket, AquamarineError)),
) -> Nil {
  case websocket.connect(host:, port:, path:, options: websocket.options()) {
    Error(err) -> process.send(ready, Error(from_gluegun(err)))
    Ok(socket) -> {
      process.send(ready, Ok(socket))
      read_loop(socket, sink)
    }
  }
}

/// Forward inbound frames into the sink until the socket ends.
///
/// A frame timeout is not the socket dying — Gluegun applies its 5s receive
/// timeout to every call, so an idle connection would otherwise be reported
/// as closed. Keep looping on `Timeout`; treat every other error as the end.
fn read_loop(socket: websocket.Socket, sink: Subject(Frame)) -> Nil {
  case websocket.receive_app_frame(socket) {
    Ok(message.Text(text)) -> {
      process.send(sink, Text(text))
      read_loop(socket, sink)
    }
    Ok(message.Binary(data)) -> {
      process.send(sink, Binary(data))
      read_loop(socket, sink)
    }
    Error(gluegun_error.Timeout) -> read_loop(socket, sink)
    // Close, CloseWithReason, and — defensively — the ping/pong arms that
    // receive_app_frame already handles, all mean "no more app frames".
    Ok(_) | Error(_) -> process.send(sink, Closed)
  }
}

/// Wrap a live Gluegun socket in a `Transport`.
fn from_socket(socket: websocket.Socket) -> Transport {
  Transport(
    send_text: fn(text) {
      websocket.send_text(socket, text)
      |> result.map_error(from_gluegun)
    },
    close: fn() {
      websocket.close(socket)
      |> result.map_error(from_gluegun)
    },
  )
}

/// Map a Gluegun error onto Aquamarine's transport-error surface.
@internal
pub fn from_gluegun(err: gluegun_error.GluegunError) -> AquamarineError {
  case err {
    gluegun_error.Timeout -> error.Transport(error.Timeout)
    gluegun_error.ConnectionDown(reason) ->
      error.Transport(error.ConnectionDown(reason))
    gluegun_error.ConnectionError(reason) ->
      error.Transport(error.ConnectionError(reason))
    gluegun_error.StreamError(reason) ->
      error.Transport(error.StreamError(reason))
    gluegun_error.InvalidOptions(reason) ->
      error.Transport(error.InvalidOptions(reason))
    gluegun_error.InvalidMessage(reason) ->
      error.Transport(error.InvalidMessage(reason))
    gluegun_error.ErlangError(reason) ->
      error.Transport(error.ErlangError(reason))
    gluegun_error.DecodeError(reason) ->
      error.Transport(error.DecodeError(reason))
  }
}
