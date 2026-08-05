//// Internal WebSocket transport seam.
////
//// `aquamarine/socket` does not call Collie directly; it operates on a
//// `Transport` value that exposes the two outbound operations the socket
//// needs: `send_text` and `close`.
////
//// Inbound frames are *pushed*: a `Connector` is handed a sink
//// `process.Subject(Frame)` at connect time and delivers every inbound frame
//// into it, including the terminal [`Closed`](#Frame). Nothing pulls.
////
//// Sending is fire-and-forget and returns nothing. A send that fails takes
//// the connection down, which arrives on the sink as `Closed` — the socket
//// actor is going to treat it that way regardless, and not needing a
//// synchronous answer is what keeps the outbound path to a single hop into
//// Collie's actor. Closing does report, because it happens once and the
//// caller has somewhere to put the answer.
////
//// Production code uses [`collie_connector`](#collie_connector). Tests build
//// an in-memory `Transport` to script inbound frames and observe outbound
//// frames deterministically.
////
//// The whole module is `@internal` — it is reachable from tests in this
//// repo but not part of the public Aquamarine API surface.

import aquamarine/error.{type AquamarineError}
import collie
import gleam/erlang/process.{type Subject}
import gleam/http
import gleam/http/request
import gleam/otp/actor
import gleam/string

/// How long to wait for Collie to answer a close.
const close_timeout_ms: Int = 5000

/// Application-level frame surfaced to the socket actor.
///
/// Collie answers pings and reassembles fragments itself, so the socket only
/// ever needs to distinguish text, binary, and "the connection is gone".
@internal
pub type Frame {
  Text(text: String)
  Binary(data: BitArray)
  Closed
}

/// Whether to speak plaintext or TLS.
///
/// `Wss` gets system CA certificates and HTTPS hostname verification by
/// default; there is no escape hatch for self-signed certificates.
pub type Scheme {
  Ws
  Wss
}

/// Transport bound to a single, already-open WebSocket connection.
///
/// Outbound only. Inbound frames arrive on the sink subject the `Connector`
/// was given.
@internal
pub type Transport {
  Transport(
    send_text: fn(String) -> Nil,
    close: fn() -> Result(Nil, AquamarineError),
  )
}

/// A function that opens a transport. `socket.start` takes one of these so
/// production and test paths share the same connect-time error handling.
///
/// Takes the sink that inbound frames should be delivered to.
@internal
pub type Connector =
  fn(Subject(Frame)) -> Result(Transport, AquamarineError)

/// Messages we send into Collie's actor. The `Connection` handle only exists
/// inside Collie's own handler, so everything outbound goes through here.
type Command {
  SendText(text: String)
  Close(reply_to: Subject(Result(Nil, AquamarineError)))
}

/// Build a Collie-backed connector.
@internal
pub fn collie_connector(
  scheme scheme: Scheme,
  host host: String,
  port port: Int,
  path path: String,
) -> Connector {
  fn(sink: Subject(Frame)) {
    let req =
      request.new()
      |> request.set_scheme(case scheme {
        Ws -> http.Http
        Wss -> http.Https
      })
      |> request.set_host(host)
      |> request.set_port(port)
      |> request.set_path(path)
      |> request.set_body("")

    let started =
      collie.new(req, Nil)
      |> collie.on_message(fn(conn, state, message) {
        case message {
          collie.Text(text) -> {
            process.send(sink, Text(text))
            collie.continue(state)
          }
          collie.Binary(data) -> {
            process.send(sink, Binary(data))
            collie.continue(state)
          }
          collie.User(SendText(text)) ->
            case collie.send_text_frame(conn, text) {
              Ok(Nil) -> collie.continue(state)
              // A send that fails means the connection is gone. Stop; the
              // close handler tells the sink.
              Error(_) -> collie.stop()
            }
          collie.User(Close(reply_to)) -> {
            let result = case
              collie.send_close_frame(
                conn,
                collie.CloseReason(collie.NormalClosure, ""),
              )
            {
              Ok(Nil) -> Ok(Nil)
              Error(reason) -> Error(from_socket_reason(reason))
            }
            process.send(reply_to, result)
            collie.stop()
          }
        }
      })
      // Fires however the connection ends — peer close, protocol error, or a
      // send that could not go out.
      |> collie.on_close(fn(_state, _reason) { process.send(sink, Closed) })
      |> collie.start

    case started {
      Ok(started) -> Ok(from_collie(started.data))
      Error(err) -> Error(from_start_error(err))
    }
  }
}

/// Wrap a live Collie client in a `Transport`.
fn from_collie(client: Subject(collie.WebsocketMessage(Command))) -> Transport {
  Transport(
    send_text: fn(text) {
      process.send(client, collie.to_user_message(SendText(text)))
    },
    close: fn() {
      let reply_to = process.new_subject()
      process.send(client, collie.to_user_message(Close(reply_to)))
      case process.receive(reply_to, close_timeout_ms) {
        Ok(result) -> result
        Error(Nil) -> Error(error.Transport(error.Timeout))
      }
    },
  )
}

/// Map a Collie socket failure onto Aquamarine's transport-error surface.
///
/// Collie names about thirty POSIX conditions. Rather than mirror all of them,
/// classify into the handful a caller can act on differently and keep Collie's
/// own name for the rest — a caller who wants the detail still has it, and one
/// who wants to branch is not forced to enumerate `Enopkg`.
@internal
pub fn from_socket_reason(reason: collie.SocketReason) -> AquamarineError {
  case reason {
    collie.Closed -> error.Transport(error.Closed)
    collie.Timeout | collie.Etimedout -> error.Transport(error.Timeout)
    collie.Econnrefused -> error.Transport(error.ConnectionRefused)
    collie.Ehostunreach
    | collie.Ehostdown
    | collie.Enetunreach
    | collie.Enetdown
    | collie.Eaddrnotavail ->
      error.Transport(error.Unreachable(collie.socket_reason_to_string(reason)))
    collie.Econnreset | collie.Econnaborted | collie.Enotconn ->
      error.Transport(
        error.ConnectionLost(collie.socket_reason_to_string(reason)),
      )
    _ ->
      error.Transport(error.SocketError(collie.socket_reason_to_string(reason)))
  }
}

/// Map a WebSocket close reason onto Aquamarine's transport-error surface.
@internal
pub fn from_close_reason(reason: collie.CloseReason) -> AquamarineError {
  case reason {
    collie.NoCloseReason -> error.Transport(error.Closed)
    collie.CloseReason(code, detail) ->
      error.Transport(error.ClosedWith(
        code: collie.close_code_to_string(code),
        reason: detail,
      ))
  }
}

/// Map a failure to start Collie's client.
///
/// Connect-time classification is coarse: the handshake runs inside Collie's
/// initialiser, so a refused connection and a rejected upgrade both arrive as
/// `InitFailed` carrying a message. The message is kept rather than flattened
/// away.
@internal
pub fn from_start_error(err: actor.StartError) -> AquamarineError {
  case err {
    actor.InitTimeout -> error.Transport(error.Timeout)
    actor.InitFailed(reason) -> error.Transport(error.ConnectFailed(reason))
    actor.InitExited(process.Normal) ->
      error.Transport(error.ConnectFailed(
        "client exited normally while connecting",
      ))
    actor.InitExited(process.Killed) ->
      error.Transport(error.ConnectFailed("client was killed while connecting"))
    actor.InitExited(process.Abnormal(reason)) ->
      error.Transport(error.ConnectFailed(string.inspect(reason)))
  }
}
