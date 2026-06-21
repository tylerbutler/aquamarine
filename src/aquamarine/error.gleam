//// Typed error surface for aquamarine.
////
//// All public operations return `Result(_, AquamarineError)`. Transport-level
//// failures are classified into Aquamarine-owned variants; channel-level
//// failures get their own variants.

import aquamarine/codec

pub type TransportError {
  /// The WebSocket upgrade failed or the Stratus actor could not complete startup.
  HandshakeFailed(reason: String)
  /// Opening the underlying socket failed before the channel could join.
  SocketConnectionFailed(reason: String)
  /// Sending a WebSocket frame failed.
  SocketSendFailed(reason: String)
  /// Receiving a WebSocket frame failed after startup.
  SocketReceiveFailed(reason: String)
  /// The host, port, path, scheme, or request configuration was invalid.
  InvalidTransportConfig(reason: String)
  /// A transport failure did not fit a stable public category.
  UnexpectedTransportFailure(reason: String)
}

pub type AquamarineError {
  Transport(TransportError)
  JoinRejected(reason: String)
  ChannelClosed
  DecodeFailed(codec.DecodeError)
  ReplyTimeout
  InternalError(reason: String)
}
