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
    /// Decide whether an inbound frame is the reply to the join sent with the
    /// given join ref. Lets refless protocols correlate joins without a ref.
    matches_reply: fn(Incoming, String) -> Bool,
    /// Interpret a join reply: `Ok(Nil)` when joined, `Error(reason)` when the
    /// server rejected the join.
    reply_status: fn(Incoming) -> Result(Nil, String),
    join_event: String,
    leave_event: String,
    reply_event: String,
    close_event: String,
    error_event: String,
    heartbeat_topic: String,
  )
}
