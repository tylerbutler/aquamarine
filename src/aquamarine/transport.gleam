//// Internal WebSocket transport seam.
////
//// `aquamarine/channel` does not call Gluegun directly; it operates on a
//// `Transport` value that exposes just the four operations the channel
//// lifecycle needs: `send_text`, `receive`, `close`, plus an `is_alive`
//// probe used by tests to assert cleanup.
////
//// Production code uses [`gluegun_connector`](#gluegun_connector) to build
//// a Gluegun-backed `Transport`. Tests can build an in-memory `Transport`
//// to script inbound frames and observe outbound frames deterministically.
////
//// The whole module is `@internal` — it is reachable from tests in this
//// repo but not part of the public Aquamarine API surface.

import aquamarine/error.{type AquamarineError}
import gleam/result
import gluegun/error as gluegun_error
import gluegun/message
import gluegun/websocket

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
@internal
pub type Transport {
  Transport(
    send_text: fn(String) -> Result(Nil, AquamarineError),
    receive: fn() -> Result(Frame, AquamarineError),
    close: fn() -> Result(Nil, AquamarineError),
  )
}

/// A function that opens a transport. `channel.connect_with` takes one of
/// these so production and test paths share the same connect-time error
/// handling.
@internal
pub type Connector =
  fn() -> Result(Transport, AquamarineError)

/// Build a Gluegun-backed connector for the given host/port/path.
@internal
pub fn gluegun_connector(
  host host: String,
  port port: Int,
  path path: String,
) -> Connector {
  fn() {
    use socket <- result.try(
      websocket.connect(host:, port:, path:, options: websocket.options())
      |> result.map_error(from_gluegun),
    )
    Ok(from_socket(socket))
  }
}

/// Wrap a live Gluegun socket in a `Transport`.
fn from_socket(socket: websocket.Socket) -> Transport {
  Transport(
    send_text: fn(text) {
      websocket.send_text(socket, text)
      |> result.map_error(from_gluegun)
    },
    receive: fn() {
      case websocket.receive_app_frame(socket) {
        Ok(message.Text(text)) -> Ok(Text(text))
        Ok(message.Binary(data)) -> Ok(Binary(data))
        Ok(message.Close) | Ok(message.CloseWithReason(_, _)) -> Ok(Closed)
        // Gluegun's receive_app_frame answers pings and skips pongs, so
        // these arms are unreachable in production. Map them defensively.
        Ok(message.Ping(_)) | Ok(message.Pong(_)) -> Ok(Closed)
        Error(err) -> Error(from_gluegun(err))
      }
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
