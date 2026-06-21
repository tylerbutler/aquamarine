import aquamarine/error
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
