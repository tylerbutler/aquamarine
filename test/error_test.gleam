import aquamarine
import aquamarine/error
import aquamarine/phoenix
import gleam/json

pub fn maps_transport_failures_to_aquamarine_owned_errors_test() {
  let result =
    aquamarine.connect(
      host: "127.0.0.1",
      port: 0,
      path: "/socket/websocket",
      topic: "test:lobby",
      payload: json.object([]),
      codec: phoenix.codec(),
    )

  assert result_is_transport_error(result)
}

fn result_is_transport_error(result) -> Bool {
  case result {
    Error(error.Transport(transport_error)) ->
      is_stable_transport_error(transport_error)
    _ -> False
  }
}

fn is_stable_transport_error(transport_error: error.TransportError) -> Bool {
  case transport_error {
    error.Timeout -> True
    error.ConnectionDown(_) -> True
    error.ConnectionError(_) -> True
    error.StreamError(_) -> True
    error.InvalidOptions(_) -> True
    error.InvalidMessage(_) -> True
    error.ErlangError(_) -> True
    error.DecodeError(_) -> True
  }
}
