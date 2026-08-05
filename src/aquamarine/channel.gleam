//// Channel client lifecycle.
////
//// A `Channel` is a handle onto a running socket actor joined to a single
//// topic, plus the codec, ref counter, and background heartbeat needed to
//// keep the channel healthy. The socket itself lives in its own process; the
//// channel holds a subject that inbound events are delivered to.
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
import aquamarine/ref
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
    counter: ref.Counter,
    heartbeat: heartbeat.Heartbeat,
    codec: Codec,
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

  use counter <- result.try(start_counter(sock))

  use join_ref <- result.try(next_join_ref(sock, counter))
  let join_frame = codec.encode_join(join_ref, topic, payload)

  use _ <- result.try(join(sock, counter, join_ref, join_frame, codec))

  use hb <- result.try(start_heartbeat(sock, counter, codec, heartbeat_ms))

  Ok(Channel(
    socket: sock,
    events: events,
    topic: topic,
    join_ref: join_ref,
    counter: counter,
    heartbeat: hb,
    codec: codec,
  ))
}

/// Push an event into the channel. Refs are assigned automatically.
///
/// Fire-and-forget: the frame is handed to the socket actor and this returns
/// immediately. It does not wait for a reply, and it cannot report a delivery
/// failure — a send that fails takes the socket down, which surfaces on the
/// next [`receive`](#receive).
pub fn push(channel: Channel, event: String, payload: json.Json) -> Nil {
  case ref.next(channel.counter) {
    Ok(ref) ->
      socket.send(
        channel.socket,
        channel.codec.encode_push(
          channel.join_ref,
          ref,
          channel.topic,
          event,
          payload,
        ),
      )
    Error(Nil) -> Nil
  }
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

/// Close the channel and underlying socket. The heartbeat and counter actors
/// are stopped first.
pub fn close(channel: Channel) -> Result(Nil, AquamarineError) {
  heartbeat.stop(channel.heartbeat)
  ref.stop(channel.counter)
  socket.close(channel.socket)
}

fn cleanup_connect(sock: Socket, counter: ref.Counter) -> Nil {
  ref.stop(counter)
  let _ = socket.close(sock)
  Nil
}

fn start_counter(sock: Socket) -> Result(ref.Counter, AquamarineError) {
  case ref.start() {
    Ok(counter) -> Ok(counter)
    Error(_) -> {
      let _ = socket.close(sock)
      Error(error.InternalError("failed to start ref counter actor"))
    }
  }
}

fn next_join_ref(
  sock: Socket,
  counter: ref.Counter,
) -> Result(String, AquamarineError) {
  case ref.next(counter) {
    Ok(join_ref) -> Ok(join_ref)
    Error(_) -> {
      cleanup_connect(sock, counter)
      Error(error.InternalError("failed to obtain join ref from counter"))
    }
  }
}

/// Send the join frame and block on its reply.
///
/// The socket actor routes the matching reply here; anything else that arrives
/// in the meantime goes to the events subject and waits there. That is the
/// whole point of the actor — the old blocking `receive` had nowhere to put
/// those frames and silently discarded them.
fn join(
  sock: Socket,
  counter: ref.Counter,
  join_ref: String,
  join_frame: String,
  codec: Codec,
) -> Result(Nil, AquamarineError) {
  let result = case
    socket.send_awaiting_reply(sock, join_ref, join_frame, join_timeout_ms)
  {
    Ok(incoming) ->
      case codec.reply_status(incoming) {
        Ok(Nil) -> Ok(Nil)
        Error(reason) -> Error(error.JoinRejected(reason))
      }
    Error(err) -> Error(err)
  }

  case result {
    Ok(Nil) -> Ok(Nil)
    Error(err) -> {
      cleanup_connect(sock, counter)
      Error(err)
    }
  }
}

fn start_heartbeat(
  sock: Socket,
  counter: ref.Counter,
  codec: Codec,
  interval_ms: Int,
) -> Result(heartbeat.Heartbeat, AquamarineError) {
  let send_fn = fn(text: String) -> Result(Nil, Nil) {
    socket.send(sock, text)
    Ok(Nil)
  }

  case heartbeat.start(send_fn, interval_ms, counter, codec) {
    Ok(hb) -> Ok(hb)
    Error(_) -> {
      cleanup_connect(sock, counter)
      Error(error.InternalError("failed to start heartbeat actor"))
    }
  }
}
