//// Typed error surface for aquamarine.
////
//// All public operations return `Result(_, AquamarineError)`. Transport-level
//// failures are classified into Aquamarine-owned variants; channel-level
//// failures get their own variants.

import aquamarine/codec

/// WebSocket transport failures, classified.
///
/// The transport names about thirty POSIX socket conditions. Rather than
/// mirror all of them, this classifies the handful a caller can act on
/// differently and keeps the underlying name as a string for the rest — the
/// detail is still there for anyone who wants it, and nobody branching on
/// "did the connection drop?" has to enumerate `Enopkg`.
pub type TransportError {
  /// The connection is closed. Nothing to retry against.
  Closed
  /// The WebSocket closed with a protocol close code.
  ClosedWith(code: String, reason: String)
  /// A socket operation exceeded its timeout.
  Timeout
  /// Nothing is listening on the other end.
  ConnectionRefused
  /// The host or network could not be reached.
  Unreachable(reason: String)
  /// An established connection was dropped underneath us.
  ConnectionLost(reason: String)
  /// The connection could not be established: refused handshake, rejected
  /// upgrade, TLS failure. Connect-time classification is coarse because the
  /// handshake happens inside the client's own initialiser.
  ConnectFailed(reason: String)
  /// Any other socket-level failure, carrying the transport's own name for it.
  SocketError(reason: String)
}

pub type AquamarineError {
  /// Underlying WebSocket transport failure (connect, send, receive, close).
  Transport(TransportError)
  /// The server rejected the join with the given reason.
  JoinRejected(reason: String)
  /// The server closed the channel.
  ChannelClosed
  /// This socket has already joined that topic. Silently replacing the routing
  /// entry would orphan the first channel's subject with no error raised
  /// anywhere, so joining twice is an error rather than a takeover.
  AlreadyJoined(topic: String)
  /// The topic is reserved by the protocol — the heartbeat topic — and cannot
  /// be joined by a channel.
  ReservedTopic(topic: String)
  /// An inbound wire frame could not be decoded.
  DecodeFailed(codec.DecodeError)
  /// Waited for a reply matching an outbound ref but it never arrived within
  /// the configured timeout.
  ReplyTimeout
  /// An internal actor or system failure (e.g. failing to start the socket
  /// actor) prevented the channel from initializing.
  InternalError(reason: String)
}
