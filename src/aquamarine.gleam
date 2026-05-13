//// Protocol-agnostic channel WebSocket client for Gleam, built on Gluegun.
////
//// This module is the public facade. It re-exports the common channel
//// lifecycle functions from `aquamarine/channel`.

import aquamarine/channel.{type Channel}
import aquamarine/codec.{type Codec, type Incoming}
import aquamarine/error.{type AquamarineError}
import gleam/json

/// Re-export of [`channel.connect`](aquamarine/channel.html#connect).
pub fn connect(
  host host: String,
  port port: Int,
  path path: String,
  topic topic: String,
  payload payload: json.Json,
  codec codec: Codec,
) -> Result(Channel, AquamarineError) {
  channel.connect(host:, port:, path:, topic:, payload:, codec:)
}

/// Re-export of [`channel.push`](aquamarine/channel.html#push).
pub fn push(
  channel: Channel,
  event: String,
  payload: json.Json,
) -> Result(Nil, AquamarineError) {
  channel.push(channel, event, payload)
}

/// Re-export of [`channel.receive`](aquamarine/channel.html#receive).
pub fn receive(channel: Channel) -> Result(Incoming, AquamarineError) {
  channel.receive(channel)
}

/// Re-export of [`channel.close`](aquamarine/channel.html#close).
pub fn close(channel: Channel) -> Result(Nil, AquamarineError) {
  channel.close(channel)
}
