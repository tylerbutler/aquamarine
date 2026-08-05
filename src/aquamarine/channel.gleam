//// Channel client lifecycle.
////
//// A `Channel` is a handle onto a running socket actor joined to a single
//// topic, plus the background heartbeat that keeps the connection healthy.
//// The socket lives in its own process and owns the transport, the codec, and
//// the ref counter; the channel holds a subject that inbound events are
//// delivered to.
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
import aquamarine/heartbeat
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
    heartbeat: heartbeat.Heartbeat,
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
  use sock <- result.try(socket.start(connector, codec, events))

  use joined <- result.try(join(sock, topic, payload))

  use hb <- result.try(start_heartbeat(sock, heartbeat_ms))

  Ok(Channel(
    socket: sock,
    events: events,
    topic: topic,
    join_ref: joined.join_ref,
    heartbeat: hb,
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

/// Close the channel and underlying socket. The heartbeat is stopped first.
pub fn close(channel: Channel) -> Result(Nil, AquamarineError) {
  heartbeat.stop(channel.heartbeat)
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

fn start_heartbeat(
  sock: Socket,
  interval_ms: Int,
) -> Result(heartbeat.Heartbeat, AquamarineError) {
  case heartbeat.start(fn() { socket.heartbeat(sock) }, interval_ms) {
    Ok(hb) -> Ok(hb)
    Error(_) -> {
      let _ = socket.close(sock)
      Error(error.InternalError("failed to start heartbeat actor"))
    }
  }
}
