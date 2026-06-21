//// Protocol-agnostic channel WebSocket client for Gleam.
////
//// This module is the public facade for the callback-based channel API.

import aquamarine/channel.{type Channel, type Config, type Handlers, type Next}
import aquamarine/codec.{type Codec, type Incoming}
import aquamarine/error.{type AquamarineError}
import gleam/dynamic.{type Dynamic}
import gleam/json

pub fn config(
  host host: String,
  port port: Int,
  path path: String,
  topic topic: String,
  payload payload: json.Json,
  codec codec: Codec,
) -> Config {
  channel.config(host:, port:, path:, topic:, payload:, codec:)
}

pub fn handlers(
  on_joined on_joined: fn(state, Dynamic) -> Next(state),
  on_message on_message: fn(state, Incoming) -> Next(state),
  on_error on_error: fn(state, AquamarineError) -> Next(state),
  on_closed on_closed: fn(state) -> Next(state),
) -> Handlers(state) {
  channel.handlers(on_joined:, on_message:, on_error:, on_closed:)
}

pub fn continue(state: state) -> Next(state) {
  channel.continue(state)
}

pub fn stop() -> Next(state) {
  channel.stop()
}

/// Re-export of [`channel.connect`](aquamarine/channel.html#connect).
pub fn connect(
  config: Config,
  handlers: Handlers(state),
  initial_state: state,
) -> Result(Channel(state), AquamarineError) {
  channel.connect(config, handlers, initial_state)
}

/// Re-export of [`channel.push`](aquamarine/channel.html#push).
pub fn push(
  channel: Channel(state),
  event: String,
  payload: json.Json,
) -> Result(Nil, AquamarineError) {
  channel.push(channel, event, payload)
}

/// Re-export of [`channel.close`](aquamarine/channel.html#close).
pub fn close(channel: Channel(state)) -> Result(Nil, AquamarineError) {
  channel.close(channel)
}
