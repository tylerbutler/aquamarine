//// Internal WebSocket transport seam.
////
//// `aquamarine/channel` operates on a `Transport` value that exposes the
//// operations the channel lifecycle needs: `send_text`, `receive`, and
//// `close`. Tests use an in-memory `Transport` (see test/support/fake_transport).
////
//// The production connector is not linked into this worktree; provide a
//// stubbed connector so unit tests and compilation succeed while runtime
//// migrations happen in later tasks.

import aquamarine/error as error
import gleam/result

@internal
pub type Frame {
  Text(text: String)
  Binary(data: BitArray)
  Closed
}

@internal
pub type Transport {
  Transport(
    send_text: fn(String) -> Result(Nil, error.AquamarineError),
    receive: fn() -> Result(Frame, error.AquamarineError),
    close: fn() -> Result(Nil, error.AquamarineError),
  )
}

@internal
pub type Connector =
  fn() -> Result(Transport, error.AquamarineError)

/// Stub connector used in production builds of this worktree. Returns an
/// `UnexpectedTransportFailure` to indicate the real connector isn't
/// available in this environment.
@internal
pub fn stratus_connector(
  host _host: String,
  port _port: Int,
  path _path: String,
) -> Connector {
  fn() {
    Error(error.Transport(error.UnexpectedTransportFailure(
      "connector unavailable in this build",
    )))
  }
}

/// Offer the same-named gluegun connector API surface so other code can
/// reference `transport.gluegun_connector` if present in other branches.
@internal
pub fn gluegun_connector(
  host _host: String,
  port _port: Int,
  path _path: String,
) -> Connector {
  fn() {
    Error(error.Transport(error.UnexpectedTransportFailure(
      "connector unavailable in this build",
    )))
  }
}

/// Helper for tests: construct a `Transport` from explicit functions.
fn transport_from(send_fn: fn(String) -> Result(Nil, error.AquamarineError), receive_fn: fn() -> Result(Frame, error.AquamarineError), close_fn: fn() -> Result(Nil, error.AquamarineError)) -> Transport {
  Transport(send_text: send_fn, receive: receive_fn, close: close_fn)
}

// Keep simple mapping helpers for future runtime adapters.
@internal
pub fn from_stratus(_any) -> error.AquamarineError {
  error.Transport(error.UnexpectedTransportFailure("stratus adapter not linked"))
}

@internal
pub fn from_gluegun(_any) -> error.AquamarineError {
  error.Transport(error.UnexpectedTransportFailure("gluegun adapter not linked"))
}
