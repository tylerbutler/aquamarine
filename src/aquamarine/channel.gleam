//// A channel: one joined topic on a socket.
////
//// A `Channel` is a handle — socket, topic, join ref, and the subject that
//// topic's inbound events are delivered to. It holds no connection of its
//// own. Many channels share one [`Socket`](aquamarine/socket.html#Socket),
//// one connection, and one heartbeat, the way Phoenix intends.
////
//// ## Two ways in
////
//// [`connect`](#connect) is the one-call path: open a connection, join a
//// topic, hand back a channel. It is the right answer for a script or a CLI
//// that wants one topic. The channel it returns **owns its socket**, so
//// [`close`](#close) on it leaves the topic *and* closes the connection.
////
//// [`join`](#join) is the path for everything else: open a
//// [`socket.connect`](aquamarine/socket.html#connect) yourself and join as
//// many topics on it as you need. Those channels do not own the socket;
//// closing one leaves its topic and nothing more.
////
//// [`leave`](#leave) is always leave-only, whichever way the channel arrived.
////
//// ## Process ownership
////
//// The events subject is owned by the process that called
//// [`connect`](#connect) or [`join`](#join), and only that process may call
//// [`receive`](#receive) — a subject can only be received from by the process
//// that created it. Everything else here is safe to call from any process,
//// since it is a message to the socket actor.

import aquamarine/codec.{type Codec, type Incoming}
import aquamarine/error.{type AquamarineError}
import aquamarine/socket.{type Socket}
import aquamarine/transport.{type Connector}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/result

/// How long [`receive`](#receive) waits for the next inbound event before
/// reporting a transport timeout.
const receive_timeout_ms: Int = 5000

/// Default wait for a join reply.
///
/// Under the old transport this rode along on Gluegun's 5s frame timeout,
/// which is not something to depend on. It is explicit now.
pub const default_join_timeout_ms: Int = 5000

pub opaque type Channel {
  Channel(
    socket: Socket,
    events: Subject(socket.Event),
    topic: String,
    join_ref: String,
    join_reply: Incoming,
    /// True only for a channel from [`connect`](#connect), which opened the
    /// connection on the caller's behalf and is therefore the only thing that
    /// can be expected to close it. Never auto-closing would leak connections
    /// for exactly the users least likely to notice.
    owns_socket: Bool,
  )
}

/// Open a WebSocket, join the given topic, and return a `Channel` ready for
/// use. The one-call path for a caller that wants a single topic.
///
/// The returned channel owns its socket: [`close`](#close) on it closes the
/// connection too. For several topics on one connection, use
/// [`socket.connect`](aquamarine/socket.html#connect) plus [`join`](#join).
///
/// Blocks until either a reply matching the join arrives, or a transport error
/// / non-ok status is observed.
pub fn connect(
  host host: String,
  port port: Int,
  path path: String,
  topic topic: String,
  payload payload: json.Json,
  codec codec: Codec,
) -> Result(Channel, AquamarineError) {
  connect_with(
    transport.gluegun_connector(host:, port:, path:),
    topic,
    payload,
    codec,
    socket.default_heartbeat_ms,
  )
}

/// Like [`connect`](#connect) but takes a `Connector` and an explicit
/// heartbeat interval, so tests can plug in an in-memory transport and a short
/// heartbeat. The channel it returns owns its socket, exactly as `connect`'s
/// does.
@internal
pub fn connect_with(
  connector: Connector,
  topic: String,
  payload: json.Json,
  codec: Codec,
  heartbeat_ms: Int,
) -> Result(Channel, AquamarineError) {
  use sock <- result.try(socket.start(connector, codec, heartbeat_ms))

  case do_join(sock, topic, payload, default_join_timeout_ms, True) {
    Ok(channel) -> Ok(channel)
    Error(err) -> {
      // We opened this connection, so we clean it up.
      let _ = socket.close(sock)
      Error(err)
    }
  }
}

/// Join a topic on an existing socket.
///
/// The channel does not own the socket — [`close`](#close) on it leaves the
/// topic and leaves the connection open for its other channels.
///
/// Blocks until the server replies. Returns `Error(AlreadyJoined(topic))` if
/// this socket has already joined that topic, and
/// `Error(JoinRejected(reason))` if the server turns it down.
pub fn join(
  socket socket: Socket,
  topic topic: String,
  payload payload: json.Json,
  timeout timeout: Int,
) -> Result(Channel, AquamarineError) {
  do_join(socket, topic, payload, timeout, False)
}

/// Push an event into the channel. Refs are assigned automatically.
///
/// Fire-and-forget: the frame is handed to the socket actor and this returns
/// immediately. It does not wait for a reply, and it cannot report a delivery
/// failure — a send that fails takes the socket down, which surfaces on the
/// next [`receive`](#receive).
pub fn push(channel: Channel, event: String, payload: json.Json) -> Nil {
  socket.push(channel.socket, channel.join_ref, channel.topic, event, payload)
}

/// Push an event and block until the server's reply to it arrives.
///
/// The reply is correlated by ref, so concurrent pushes from different
/// processes each get their own. Frames that arrive while waiting are
/// delivered to [`receive`](#receive) as usual — they are not dropped.
///
/// Returns `Error(ReplyTimeout)` if no reply arrives within `timeout`, and
/// `Error(ChannelClosed)` if the socket goes away first. A reply carrying a
/// non-ok status is an ordinary `Ok` — interpreting it is the caller's job.
pub fn push_and_await_reply(
  channel: Channel,
  event: String,
  payload: json.Json,
  timeout: Int,
) -> Result(Incoming, AquamarineError) {
  socket.push_and_await_reply(
    channel.socket,
    channel.join_ref,
    channel.topic,
    event,
    payload,
    timeout,
  )
}

/// Receive the next inbound event on the channel.
///
/// Only this topic's frames arrive here. Heartbeat replies never do, so the
/// caller sees real channel activity and nothing else. Returns
/// `Error(ChannelClosed)` if the server sent a close/error event for this
/// topic, or the socket itself closed.
pub fn receive(channel: Channel) -> Result(Incoming, AquamarineError) {
  case process.receive(channel.events, receive_timeout_ms) {
    Ok(event) -> event
    Error(Nil) -> Error(error.Transport(error.Timeout))
  }
}

/// Leave the topic. Always leave-only: the socket stays open, and its other
/// channels are unaffected.
///
/// Re-joining the same topic afterwards is fine.
pub fn leave(channel: Channel) -> Result(Nil, AquamarineError) {
  socket.leave(channel.socket, channel.topic, channel.join_ref)
}

/// Leave the topic, and close the connection if this channel owns it.
///
/// A channel from [`connect`](#connect) owns its socket, so this closes the
/// connection. A channel from [`join`](#join) does not, so this is exactly
/// [`leave`](#leave). Use `leave` when you mean leave regardless.
pub fn close(channel: Channel) -> Result(Nil, AquamarineError) {
  case channel.owns_socket {
    True -> socket.close(channel.socket)
    False -> leave(channel)
  }
}

/// The reply the server accepted the join with.
///
/// Lets a caller inspect the live join payload — what the server actually
/// answered — rather than having to re-decode frames or fabricate it.
pub fn join_reply(channel: Channel) -> Incoming {
  channel.join_reply
}

/// The topic this channel is joined to.
pub fn topic(channel: Channel) -> String {
  channel.topic
}

/// The socket this channel rides on, for joining further topics on the same
/// connection.
pub fn socket(channel: Channel) -> Socket {
  channel.socket
}

/// The subject inbound events are delivered on.
///
/// [`receive`](#receive) is the easy path and stays the right answer for
/// scripts and CLIs. This is for callers who already have an OTP application
/// and want to select on channel events alongside their own messages.
pub fn events(channel: Channel) -> Subject(socket.Event) {
  channel.events
}

fn do_join(
  sock: Socket,
  topic: String,
  payload: json.Json,
  timeout: Int,
  owns_socket: Bool,
) -> Result(Channel, AquamarineError) {
  // Created here, so the joining process is the one that may receive from it.
  let events = process.new_subject()
  use joined <- result.map(socket.join(sock, topic, payload, events, timeout))

  Channel(
    socket: sock,
    events: events,
    topic: topic,
    join_ref: joined.join_ref,
    join_reply: joined.reply,
    owns_socket: owns_socket,
  )
}
