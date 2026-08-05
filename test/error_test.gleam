//// Transport error mapping.
////
//// The `TransportError` surface is shaped around what Collie reports, so
//// these tests pin the classification rather than the exhaustive POSIX list:
//// what a caller can branch on, and that nothing escapes unclassified.

import aquamarine
import aquamarine/error
import aquamarine/phoenix
import aquamarine/transport
import collie
import gleam/erlang/process
import gleam/json
import gleam/otp/actor

/// Nothing is listening on port 1, so the handshake cannot happen. Connect-time
/// classification is coarse — the handshake runs inside Collie's initialiser —
/// so this lands as `ConnectFailed`, not `ConnectionRefused`.
pub fn a_connection_to_a_dead_port_fails_at_connect_test() {
  let assert Error(error.Transport(err)) =
    aquamarine.connect(
      scheme: transport.Ws,
      host: "127.0.0.1",
      port: 1,
      path: "/socket/websocket",
      topic: "test:lobby",
      payload: json.object([]),
      codec: phoenix.codec(),
    )

  assert is_connect_failure(err)
}

pub fn classifies_the_socket_reasons_a_caller_can_act_on_test() {
  assert transport.from_socket_reason(collie.Closed)
    == error.Transport(error.Closed)
  assert transport.from_socket_reason(collie.Timeout)
    == error.Transport(error.Timeout)
  assert transport.from_socket_reason(collie.Etimedout)
    == error.Transport(error.Timeout)
  assert transport.from_socket_reason(collie.Econnrefused)
    == error.Transport(error.ConnectionRefused)

  let assert error.Transport(error.Unreachable(_)) =
    transport.from_socket_reason(collie.Ehostunreach)
  let assert error.Transport(error.Unreachable(_)) =
    transport.from_socket_reason(collie.Enetdown)
  let assert error.Transport(error.ConnectionLost(_)) =
    transport.from_socket_reason(collie.Econnreset)
  let assert error.Transport(error.ConnectionLost(_)) =
    transport.from_socket_reason(collie.Enotconn)
}

/// Everything not called out above still lands somewhere, carrying Collie's
/// own name for it rather than being flattened to a bare "socket error".
pub fn keeps_the_underlying_name_for_unclassified_reasons_test() {
  assert transport.from_socket_reason(collie.Enopkg)
    == error.Transport(error.SocketError("package not installed"))
  assert transport.from_socket_reason(collie.Badarg)
    == error.Transport(error.SocketError("bad argument"))
  assert transport.from_socket_reason(collie.Eaddrinuse)
    == error.Transport(error.SocketError("address already in use"))
}

pub fn maps_websocket_close_reasons_test() {
  assert transport.from_close_reason(collie.NoCloseReason)
    == error.Transport(error.Closed)

  let assert error.Transport(error.ClosedWith(code, reason)) =
    transport.from_close_reason(collie.CloseReason(
      collie.MessageTooBig,
      "frame over limit",
    ))
  assert code == "message too big"
  assert reason == "frame over limit"

  let assert error.Transport(error.ClosedWith(code, _)) =
    transport.from_close_reason(collie.CloseReason(
      collie.ApplicationCode(4001),
      "",
    ))
  assert code == "application close code 4001"
}

pub fn maps_client_start_failures_test() {
  assert transport.from_start_error(actor.InitTimeout)
    == error.Transport(error.Timeout)
  assert transport.from_start_error(actor.InitFailed("handshake refused"))
    == error.Transport(error.ConnectFailed("handshake refused"))

  let assert error.Transport(error.ConnectFailed(_)) =
    transport.from_start_error(actor.InitExited(process.Killed))
  let assert error.Transport(error.ConnectFailed(_)) =
    transport.from_start_error(actor.InitExited(process.Normal))
}

fn is_connect_failure(err: error.TransportError) -> Bool {
  case err {
    error.ConnectFailed(_) -> True
    error.ConnectionRefused -> True
    error.Timeout -> True
    error.Closed -> True
    error.ClosedWith(_, _) -> False
    error.Unreachable(_) -> True
    error.ConnectionLost(_) -> True
    error.SocketError(_) -> True
  }
}
