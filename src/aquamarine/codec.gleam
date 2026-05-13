import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/option.{type Option}

pub type Incoming {
  Incoming(
    join_ref: Option(String),
    ref: Option(String),
    topic: String,
    event: String,
    payload: Dynamic,
  )
}

pub type DecodeError {
  InvalidJson(reason: String)
  InvalidFormat(reason: String)
}

pub type Codec {
  Codec(
    decode: fn(String) -> Result(Incoming, DecodeError),
    encode_join: fn(String, String, json.Json) -> String,
    encode_push: fn(String, String, String, String, json.Json) -> String,
    encode_heartbeat: fn(String) -> String,
    join_event: String,
    reply_event: String,
    close_event: String,
    error_event: String,
    heartbeat_topic: String,
  )
}
