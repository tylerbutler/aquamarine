//// Channel client lifecycle.
////
//// A `Channel` wraps a WebSocket transport joined to a single topic, plus the
//// codec, ref counter, and background heartbeat needed to keep the channel
//// healthy.
////
//// ## Process ownership
////
//// The transport is owned by the process that called [`connect`](#connect).
//// Only that process may call [`receive`](#receive). [`push`](#push) and
//// [`close`](#close) are safe to call from any process, since the underlying
//// `send_text` is fire-and-forget.

import aquamarine/codec.{type Codec, type Incoming}
import aquamarine/error as error
import aquamarine/error.{type AquamarineError}
import aquamarine/heartbeat
import aquamarine/ref
import aquamarine/transport.{type Connector, type Transport}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import gleam/result

pub type Config {
  Config(
    host: String,
    port: Int,
    path: String,
    topic: String,
    payload: json.Json,
    codec: Codec,
  )
}

pub type Handlers(state) {
  Handlers(
    on_joined: fn(state, Dynamic) -> Next(state),
    on_message: fn(state, Incoming) -> Next(state),
    on_error: fn(state, AquamarineError) -> Next(state),
    on_closed: fn(state) -> Next(state),
  )
}

pub type Next(state) {
  Continue(state)
  Stop
}

/// Default heartbeat interval, matching the Phoenix JS client.
const default_heartbeat_ms: Int = 30_000

pub opaque type Channel(state) {
  Channel(
    transport: Transport,
    topic: String,
    join_ref: String,
    counter: ref.Counter,
    heartbeat: heartbeat.Heartbeat,
    codec: Codec,
  )
}

pub fn continue(state: state) -> Next(state) {
  Continue(state)
}

pub fn stop() -> Next(state) {
  Stop
}

pub fn config(
  host host: String,
  port port: Int,
  path path: String,
  topic topic: String,
  payload payload: json.Json,
  codec codec: Codec,
) -> Config {
  Config(host:, port:, path:, topic:, payload:, codec:)
}

pub fn handlers(
  on_joined on_joined: fn(state, Dynamic) -> Next(state),
  on_message on_message: fn(state, Incoming) -> Next(state),
  on_error on_error: fn(state, AquamarineError) -> Next(state),
  on_closed on_closed: fn(state) -> Next(state),
) -> Handlers(state) {
  Handlers(on_joined:, on_message:, on_error:, on_closed:)
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

pub fn connect(
  _config: Config,
  _handlers: Handlers(state),
  _initial_state: state,
) -> Result(Channel(state), AquamarineError) {
  Error(error.InternalError("callback runtime not implemented"))
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
  use tx <- result.try(connector())

  use counter <- result.try(start_counter(tx))

  use join_ref <- result.try(next_join_ref(tx, counter))
  let join_frame = codec.encode_join(join_ref, topic, payload)

  use _ <- result.try(send_join(tx, counter, join_frame))

  use _ <- result.try(await_join_reply_with_cleanup(
    tx,
    counter,
    join_ref,
    codec,
  ))

  let send_fn = fn(text: String) -> Result(Nil, Nil) {
    tx.send_text(text)
    |> result.map_error(fn(_) { Nil })
  }

  use hb <- result.try(start_heartbeat(
    tx,
    counter,
    send_fn,
    codec,
    heartbeat_ms,
  ))

  Ok(Channel(
    transport: tx,
    topic: topic,
    join_ref: join_ref,
    counter: counter,
    heartbeat: hb,
    codec: codec,
  ))
}

/// Push an event into the channel. Refs are assigned automatically.
///
/// Returns `Ok(Nil)` once the frame is handed to the transport. This does
/// **not** wait for a reply.
pub fn push(
  channel: Channel(state),
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
  channel.transport.send_text(text)
}

/// Receive the next inbound frame on the channel.
///
/// Skips heartbeat replies so the caller only sees real channel activity.
/// Returns `Error(ChannelClosed)` if the server sent a close/error event, or
/// the socket itself closed.
pub fn receive(channel: Channel(state)) -> Result(Incoming, AquamarineError) {
  do_receive(channel)
}

fn do_receive(channel: Channel(state)) -> Result(Incoming, AquamarineError) {
  use frame <- result.try(channel.transport.receive())

  case frame {
    transport.Text(text) ->
      case channel.codec.decode(text) {
        Ok(incoming) -> handle_incoming(channel, incoming)
        Error(err) -> Error(error.DecodeFailed(err))
      }
    transport.Binary(_) -> do_receive(channel)
    transport.Closed -> Error(error.ChannelClosed)
  }
}

fn handle_incoming(
  channel: Channel(state),
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

/// Close the channel and underlying transport. The heartbeat and counter
/// actors are stopped first.
pub fn close(channel: Channel(state)) -> Result(Nil, AquamarineError) {
  heartbeat.stop(channel.heartbeat)
  ref.stop(channel.counter)
  channel.transport.close()
}

fn cleanup_connect(tx: Transport, counter: ref.Counter) -> Nil {
  ref.stop(counter)
  let _ = tx.close()
  Nil
}

fn start_counter(tx: Transport) -> Result(ref.Counter, AquamarineError) {
  case ref.start() {
    Ok(counter) -> Ok(counter)
    Error(_) -> {
      let _ = tx.close()
      Error(error.InternalError("failed to start ref counter actor"))
    }
  }
}

fn next_join_ref(
  tx: Transport,
  counter: ref.Counter,
) -> Result(String, AquamarineError) {
  case ref.next(counter) {
    Ok(join_ref) -> Ok(join_ref)
    Error(_) -> {
      cleanup_connect(tx, counter)
      Error(error.InternalError("failed to obtain join ref from counter"))
    }
  }
}

fn send_join(
  tx: Transport,
  counter: ref.Counter,
  join_frame: String,
) -> Result(Nil, AquamarineError) {
  case tx.send_text(join_frame) {
    Ok(_) -> Ok(Nil)
    Error(err) -> {
      cleanup_connect(tx, counter)
      Error(err)
    }
  }
}

fn await_join_reply_with_cleanup(
  tx: Transport,
  counter: ref.Counter,
  join_ref: String,
  codec: Codec,
) -> Result(Nil, AquamarineError) {
  case await_join_reply(tx, join_ref, codec) {
    Ok(_) -> Ok(Nil)
    Error(err) -> {
      cleanup_connect(tx, counter)
      Error(err)
    }
  }
}

fn start_heartbeat(
  tx: Transport,
  counter: ref.Counter,
  send_fn: fn(String) -> Result(Nil, Nil),
  codec: Codec,
  interval_ms: Int,
) -> Result(heartbeat.Heartbeat, AquamarineError) {
  case heartbeat.start(send_fn, interval_ms, counter, codec) {
    Ok(hb) -> Ok(hb)
    Error(_) -> {
      cleanup_connect(tx, counter)
      Error(error.InternalError("failed to start heartbeat actor"))
    }
  }
}

fn await_join_reply(
  tx: Transport,
  join_ref: String,
  codec: Codec,
) -> Result(Nil, AquamarineError) {
  use frame <- result.try(tx.receive())

  case frame {
    transport.Text(text) ->
      case codec.decode(text) {
        Ok(incoming) -> match_join_reply(tx, join_ref, incoming, codec)
        Error(err) -> Error(error.DecodeFailed(err))
      }
    transport.Closed -> Error(error.ChannelClosed)
    transport.Binary(_) -> await_join_reply(tx, join_ref, codec)
  }
}

fn match_join_reply(
  tx: Transport,
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
    _, _ -> await_join_reply(tx, join_ref, codec)
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
