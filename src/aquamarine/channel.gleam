//// Channel client lifecycle.
////
//// A `Channel` wraps a Gluegun WebSocket socket joined to a single topic,
//// plus the codec, ref counter, and background heartbeat needed to keep the
//// channel healthy.
////
//// ## Process ownership
////
//// The socket is owned by the process that called [`connect`](#connect).
//// Only that process may call [`receive`](#receive). [`push`](#push) and
//// [`close`](#close) are safe to call from any process, since Gun's
//// `ws_send` is fire-and-forget.

import aquamarine/codec.{type Codec, type Incoming}
import aquamarine/error.{type AquamarineError}
import aquamarine/heartbeat
import aquamarine/ref
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import gleam/result
import gluegun/message
import gluegun/websocket

/// Default heartbeat interval, matching the Phoenix JS client.
const default_heartbeat_ms: Int = 30_000

pub opaque type Channel {
  Channel(
    socket: websocket.Socket,
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
  use socket <- result.try(
    websocket.connect(host:, port:, path:, options: websocket.options())
    |> result.map_error(error.from_gluegun),
  )

  use counter <- result.try(start_counter(socket))

  use join_ref <- result.try(next_join_ref(socket, counter))
  let join_frame = codec.encode_join(join_ref, topic, payload)

  use _ <- result.try(send_join(socket, counter, join_frame))

  use _ <- result.try(await_join_reply_with_cleanup(
    socket,
    counter,
    join_ref,
    codec,
  ))

  // Send queue + receive happen in the caller's process. The heartbeat
  // actor runs separately and only sends, which Gluegun allows from any
  // process.
  let send_fn = fn(text: String) -> Result(Nil, Nil) {
    websocket.send_text(socket, text)
    |> result.map_error(fn(_) { Nil })
  }

  use hb <- result.try(start_heartbeat(socket, counter, send_fn, codec))

  Ok(Channel(
    socket: socket,
    topic: topic,
    join_ref: join_ref,
    counter: counter,
    heartbeat: hb,
    codec: codec,
  ))
}

/// Push an event into the channel. Refs are assigned automatically.
///
/// Returns `Ok(Nil)` once the frame is handed to Gun. This does **not** wait
/// for a reply.
pub fn push(
  channel: Channel,
  event: String,
  payload: json.Json,
) -> Result(Nil, AquamarineError) {
  use ref <- result.try(
    ref.next(channel.counter)
    |> result.map_error(fn(_) { error.ChannelClosed }),
  )
  let text =
    channel.codec.encode_push(
      channel.join_ref,
      ref,
      channel.topic,
      event,
      payload,
    )
  websocket.send_text(channel.socket, text)
  |> result.map_error(error.from_gluegun)
}

/// Receive the next inbound frame on the channel.
///
/// Skips heartbeat replies so the caller only sees real channel activity.
/// Returns `Error(ChannelClosed)` if the server sent a close/error event, or
/// the socket itself closed.
pub fn receive(channel: Channel) -> Result(Incoming, AquamarineError) {
  do_receive(channel)
}

fn do_receive(channel: Channel) -> Result(Incoming, AquamarineError) {
  use raw <- result.try(
    websocket.receive_app_frame(channel.socket)
    |> result.map_error(error.from_gluegun),
  )

  case raw {
    message.Text(text) ->
      case channel.codec.decode(text) {
        Ok(incoming) -> handle_incoming(channel, incoming)
        Error(err) -> Error(error.DecodeFailed(err))
      }
    message.Binary(_) -> do_receive(channel)
    message.Close | message.CloseWithReason(_, _) -> Error(error.ChannelClosed)
    message.Ping(_) | message.Pong(_) -> do_receive(channel)
  }
}

fn handle_incoming(
  channel: Channel,
  incoming: Incoming,
) -> Result(Incoming, AquamarineError) {
  case incoming.event {
    e if e == channel.codec.close_event -> Error(error.ChannelClosed)
    e if e == channel.codec.error_event -> Error(error.ChannelClosed)
    e
      if e == channel.codec.reply_event
      && incoming.topic == channel.codec.heartbeat_topic
    -> do_receive(channel)
    _ -> Ok(incoming)
  }
}

/// Close the channel and underlying WebSocket. The heartbeat actor is stopped
/// first.
pub fn close(channel: Channel) -> Result(Nil, AquamarineError) {
  heartbeat.stop(channel.heartbeat)
  ref.stop(channel.counter)
  websocket.close(channel.socket)
  |> result.map_error(error.from_gluegun)
}

fn cleanup_connect(socket: websocket.Socket, counter: ref.Counter) -> Nil {
  ref.stop(counter)
  let _ = websocket.close(socket)
  Nil
}

fn start_counter(
  socket: websocket.Socket,
) -> Result(ref.Counter, AquamarineError) {
  case ref.start() {
    Ok(counter) -> Ok(counter)
    Error(_) -> {
      let _ = websocket.close(socket)
      Error(error.ReplyTimeout)
    }
  }
}

fn next_join_ref(
  socket: websocket.Socket,
  counter: ref.Counter,
) -> Result(String, AquamarineError) {
  case ref.next(counter) {
    Ok(join_ref) -> Ok(join_ref)
    Error(_) -> {
      cleanup_connect(socket, counter)
      Error(error.ReplyTimeout)
    }
  }
}

fn send_join(
  socket: websocket.Socket,
  counter: ref.Counter,
  join_frame: String,
) -> Result(Nil, AquamarineError) {
  case websocket.send_text(socket, join_frame) {
    Ok(_) -> Ok(Nil)
    Error(err) -> {
      cleanup_connect(socket, counter)
      Error(error.from_gluegun(err))
    }
  }
}

fn await_join_reply_with_cleanup(
  socket: websocket.Socket,
  counter: ref.Counter,
  join_ref: String,
  codec: Codec,
) -> Result(Nil, AquamarineError) {
  case await_join_reply(socket, join_ref, codec) {
    Ok(_) -> Ok(Nil)
    Error(err) -> {
      cleanup_connect(socket, counter)
      Error(err)
    }
  }
}

fn start_heartbeat(
  socket: websocket.Socket,
  counter: ref.Counter,
  send_fn: fn(String) -> Result(Nil, Nil),
  codec: Codec,
) -> Result(heartbeat.Heartbeat, AquamarineError) {
  case heartbeat.start(send_fn, default_heartbeat_ms, counter, codec) {
    Ok(hb) -> Ok(hb)
    Error(_) -> {
      cleanup_connect(socket, counter)
      Error(error.ReplyTimeout)
    }
  }
}

fn await_join_reply(
  socket: websocket.Socket,
  join_ref: String,
  codec: Codec,
) -> Result(Nil, AquamarineError) {
  use raw <- result.try(
    websocket.receive_app_frame(socket)
    |> result.map_error(error.from_gluegun),
  )

  case raw {
    message.Text(text) ->
      case codec.decode(text) {
        Ok(incoming) -> match_join_reply(socket, join_ref, incoming, codec)
        Error(err) -> Error(error.DecodeFailed(err))
      }
    message.Close | message.CloseWithReason(_, _) -> Error(error.ChannelClosed)
    _ -> await_join_reply(socket, join_ref, codec)
  }
}

fn match_join_reply(
  socket: websocket.Socket,
  join_ref: String,
  incoming: Incoming,
  codec: Codec,
) -> Result(Nil, AquamarineError) {
  case incoming.event, incoming.ref {
    event, Some(reply_ref)
      if event == codec.reply_event && reply_ref == join_ref
    ->
      case decode_reply_status(incoming.payload) {
        Ok("ok") -> Ok(Nil)
        Ok(other) -> Error(error.JoinRejected(other))
        Error(_) -> Error(error.JoinRejected("malformed reply"))
      }
    _, _ -> await_join_reply(socket, join_ref, codec)
  }
}

fn decode_reply_status(payload: Dynamic) -> Result(String, Nil) {
  let decoder = {
    use status <- decode.field("status", decode.string)
    decode.success(status)
  }
  decode.run(payload, decoder)
  |> result.map_error(fn(_) { Nil })
}
