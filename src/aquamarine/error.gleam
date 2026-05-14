//// Typed error surface for aquamarine.
////
//// All public operations return `Result(_, AquamarineError)`. Transport-level
//// failures are classified into Aquamarine-owned variants; channel-level
//// failures get their own variants.

import aquamarine/codec

pub type TransportError {
  Timeout
  ConnectionDown(reason: String)
  ConnectionError(reason: String)
  StreamError(reason: String)
  InvalidOptions(reason: String)
  InvalidMessage(reason: String)
  ErlangError(reason: String)
  DecodeError(reason: String)
}

pub type AquamarineError {
  /// Underlying WebSocket transport failure (connect, send, receive, close).
  Transport(TransportError)
  /// The server rejected the join with the given reason.
  JoinRejected(reason: String)
  /// The server closed the channel.
  ChannelClosed
  /// An inbound wire frame could not be decoded.
  DecodeFailed(codec.DecodeError)
  /// Waited for a reply matching an outbound ref but it never arrived within
  /// the configured timeout.
  ReplyTimeout
}
