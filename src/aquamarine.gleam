//// Protocol-agnostic channel WebSocket client for Gleam.
////
//// This module is the public facade for the one-topic case: connect, push,
//// receive, close. It re-exports `aquamarine/channel`.
////
//// For several topics on one connection, use `aquamarine/socket` and
//// `aquamarine/channel` directly — open a socket once and `channel.join` as
//// many topics as you need.

import aquamarine/channel.{type Channel}
import aquamarine/codec.{type Codec, type Incoming}
import aquamarine/error.{type AquamarineError}
import aquamarine/transport
import gleam/json

/// Re-export of [`channel.connect`](aquamarine/channel.html#connect).
pub fn connect(
  scheme scheme: transport.Scheme,
  host host: String,
  port port: Int,
  path path: String,
  topic topic: String,
  payload payload: json.Json,
  codec codec: Codec,
) -> Result(Channel, AquamarineError) {
  channel.connect(scheme:, host:, port:, path:, topic:, payload:, codec:)
}

/// Re-export of [`channel.push`](aquamarine/channel.html#push).
pub fn push(channel: Channel, event: String, payload: json.Json) -> Nil {
  channel.push(channel, event, payload)
}

/// Re-export of
/// [`channel.push_and_await_reply`](aquamarine/channel.html#push_and_await_reply).
pub fn push_and_await_reply(
  channel: Channel,
  event: String,
  payload: json.Json,
  timeout: Int,
) -> Result(Incoming, AquamarineError) {
  channel.push_and_await_reply(channel, event, payload, timeout)
}

/// Re-export of [`channel.join_reply`](aquamarine/channel.html#join_reply).
pub fn join_reply(channel: Channel) -> Incoming {
  channel.join_reply(channel)
}

/// Re-export of [`channel.receive`](aquamarine/channel.html#receive).
pub fn receive(
  channel: Channel,
  timeout: Int,
) -> Result(Incoming, AquamarineError) {
  channel.receive(channel, timeout)
}

/// Re-export of [`channel.leave`](aquamarine/channel.html#leave).
pub fn leave(channel: Channel) -> Result(Nil, AquamarineError) {
  channel.leave(channel)
}

/// Re-export of [`channel.close`](aquamarine/channel.html#close).
pub fn close(channel: Channel) -> Result(Nil, AquamarineError) {
  channel.close(channel)
}
