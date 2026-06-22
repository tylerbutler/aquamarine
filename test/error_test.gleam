import aquamarine/channel
import aquamarine/error
import gleam/otp/actor
import gleeunit/should

pub fn transport_errors_are_stable_test() {
  [
    error.HandshakeFailed("bad upgrade"),
    error.SocketConnectionFailed("econnrefused"),
    error.SocketSendFailed("closed"),
    error.SocketReceiveFailed("timeout"),
    error.InvalidTransportConfig("bad request"),
    error.UnexpectedTransportFailure("actor exited"),
  ]
  |> list_all_stable
  |> should.equal(True)
}

pub fn websocket_handshake_start_errors_are_handshake_failures_test() {
  channel.map_start_error(actor.InitFailed(
    "WebSocket handshake failed: invalid upgrade response",
  ))
  |> should.equal(
    error.Transport(error.HandshakeFailed(
      "WebSocket handshake failed: invalid upgrade response",
    )),
  )
}

pub fn websocket_socket_start_errors_are_connection_failures_test() {
  channel.map_start_error(actor.InitFailed(
    "WebSocket handshake failed: Sock(Econnrefused)",
  ))
  |> should.equal(
    error.Transport(error.SocketConnectionFailed(
      "WebSocket handshake failed: Sock(Econnrefused)",
    )),
  )
}

fn list_all_stable(errors: List(error.TransportError)) -> Bool {
  case errors {
    [] -> True
    [first, ..rest] ->
      case first {
        error.HandshakeFailed(_) -> list_all_stable(rest)
        error.SocketConnectionFailed(_) -> list_all_stable(rest)
        error.SocketSendFailed(_) -> list_all_stable(rest)
        error.SocketReceiveFailed(_) -> list_all_stable(rest)
        error.InvalidTransportConfig(_) -> list_all_stable(rest)
        error.UnexpectedTransportFailure(_) -> list_all_stable(rest)
      }
  }
}
