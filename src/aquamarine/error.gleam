//// Typed error surface for aquamarine.
////
//// All public operations return `Result(_, AquamarineError)`. Transport-level
//// failures from Gluegun are wrapped in `Transport`; channel-level failures
//// get their own variants.

import aquamarine/codec
import gluegun/error as gluegun

pub type AquamarineError {
  /// Underlying WebSocket transport failure from Gluegun (connect, send,
  /// receive, close).
  Transport(gluegun.GluegunError)
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

/// Lift a Gluegun error into an `AquamarineError`.
pub fn from_gluegun(err: gluegun.GluegunError) -> AquamarineError {
  Transport(err)
}
