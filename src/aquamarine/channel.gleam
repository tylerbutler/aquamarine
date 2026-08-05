//// Channel client lifecycle.
////
//// A `Channel` is a handle onto a running socket actor joined to a single
//// topic. The socket lives in its own process and owns everything with
//// state — the transport, the codec, the ref counter, and the heartbeat
//// timer. The channel holds a subject that inbound events are delivered to.
////
//// ## Process ownership
////
//// The events subject is owned by the process that called
//// [`connect`](#connect), and only that process may call
//// [`receive`](#receive) — a subject can only be received from by the process
//// that created it. [`push`](#push) and [`close`](#close) are safe to call
//// from any process, since they are messages to the socket actor.

import aquamarine/codec.{type Codec, type Incoming}
import aquamarine/error.{type AquamarineError}
import aquamarine/socket.{type Socket}
import aquamarine/transport.{type Connector}
import gleam/erlang/process.{type Subject}
import gleam/json
import gleam/result

/// Default heartbeat interval, matching the Phoenix JS client.
const default_heartbeat_ms: Int = 30_000

/// How long [`receive`](#receive) waits for the next inbound event before
/// reporting a transport timeout.
const receive_timeout_ms: Int = 5000

/// How long [`connect`](#connect) waits for the join reply.
const join_timeout_ms: Int = 5000

pub opaque type Channel {
  Channel(
    socket: Socket,
    events: Subject(socket.Event),
    topic: String,
    join_ref: String,
    join_reply: Incoming,
  )
}

/// Open a WebSocket to a compatible server, join the given topic with the
/// supplied payload, and return a `Channel` ready for use.
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
    default_heartbeat_ms,
  )
}

/// Like [`connect`](#connect) but takes a `Connector` and an explicit
/// heartbeat interval. Used by tests to plug in an in-memory transport and a
/// short heartbeat, and by the public `connect` to wire up a Gluegun-backed
/// transport with the production interval.
@internal
pub fn connect_with(
  connector: Connector,
  topic: String,
  payload: json.Json,
  codec: Codec,
  heartbeat_ms: Int,
) -> Result(Channel, AquamarineError) {
  let events = process.new_subject()
  use sock <- result.try(socket.start(connector, codec, events, heartbeat_ms))

  use joined <- result.try(join(sock, topic, payload))

  Ok(Channel(
    socket: sock,
    events: events,
    topic: topic,
    join_ref: joined.join_ref,
    join_reply: joined.reply,
  ))
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

/// The reply the server accepted the join with.
///
/// Lets a caller inspect the live join payload — what the server actually
/// answered — rather than having to re-decode frames or fabricate it.
pub fn join_reply(channel: Channel) -> Incoming {
  channel.join_reply
}

/// The subject inbound events are delivered on.
///
/// [`receive`](#receive) is the easy path and stays the right answer for
/// scripts and CLIs. This is for callers who already have an OTP application
/// and want to select on channel events alongside their own messages.
pub fn events(channel: Channel) -> Subject(socket.Event) {
  channel.events
}

/// Receive the next inbound event on the channel.
///
/// Skips heartbeat replies so the caller only sees real channel activity.
/// Returns `Error(ChannelClosed)` if the server sent a close/error event, or
/// the socket itself closed.
pub fn receive(channel: Channel) -> Result(Incoming, AquamarineError) {
  case process.receive(channel.events, receive_timeout_ms) {
    Ok(event) -> event
    Error(Nil) -> Error(error.Transport(error.Timeout))
  }
}

/// Close the channel and underlying socket. Stopping the socket actor stops
/// the heartbeat with it.
pub fn close(channel: Channel) -> Result(Nil, AquamarineError) {
  socket.close(channel.socket)
}

/// Join the topic and block on the reply.
///
/// The socket actor mints the join ref, sends the frame, and routes the
/// matching reply here; anything else that arrives in the meantime goes to the
/// events subject and waits there. That is the whole point of the actor — the
/// old blocking `receive` had nowhere to put those frames and discarded them.
fn join(
  sock: Socket,
  topic: String,
  payload: json.Json,
) -> Result(socket.Joined, AquamarineError) {
  case socket.join(sock, topic, payload, join_timeout_ms) {
    Ok(joined) -> Ok(joined)
    Error(err) -> {
      let _ = socket.close(sock)
      Error(err)
    }
  }
}
