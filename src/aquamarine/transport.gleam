//// Internal transport seam used only by legacy tests.
////
//// Production runtime now uses Stratus directly. This module remains as a
//// small in-memory seam so `channel.connect_with` and the fake transport tests
//// can keep exercising the legacy receive/push logic until later tasks remove
//// it completely.

import aquamarine/error

/// Application-level frame surfaced to the legacy channel layer.
@internal
pub type Frame {
  Text(text: String)
  Binary(data: BitArray)
  Closed
}

/// Transport bound to a single, already-open test socket.
@internal
pub type Transport {
  Transport(
    send_text: fn(String) -> Result(Nil, error.AquamarineError),
    receive: fn() -> Result(Frame, error.AquamarineError),
    close: fn() -> Result(Nil, error.AquamarineError),
  )
}

/// A function that opens a transport for legacy tests.
@internal
pub type Connector =
  fn() -> Result(Transport, error.AquamarineError)
