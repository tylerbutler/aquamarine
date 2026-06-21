import aquamarine/error
import startest.{describe, it}
import startest/expect

pub fn error_tests() {
  describe("public error surface", [
    it("keeps transport errors in Aquamarine-owned categories", fn() {
      [
        error.HandshakeFailed("bad upgrade"),
        error.SocketConnectionFailed("econnrefused"),
        error.SocketSendFailed("closed"),
        error.SocketReceiveFailed("timeout"),
        error.InvalidTransportConfig("bad request"),
        error.UnexpectedTransportFailure("actor exited"),
      ]
      |> list_all_stable
      |> expect.to_equal(True)
    }),
  ])
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
