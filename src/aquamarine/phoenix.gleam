import aquamarine/codec as aquamarine_codec
import gleam/json
import gleam/option.{Some}
import roost/frame as roost_frame

pub fn codec() -> aquamarine_codec.Codec {
  aquamarine_codec.Codec(
    decode: decode,
    encode_join: encode_join,
    encode_push: encode_push,
    encode_heartbeat: roost_frame.encode_heartbeat,
    matches_reply: matches_reply,
    reply_status: reply_status,
    join_event: roost_frame.join_event,
    leave_event: roost_frame.leave_event,
    reply_event: roost_frame.reply_event,
    close_event: roost_frame.close_event,
    error_event: roost_frame.error_event,
    heartbeat_topic: roost_frame.heartbeat_topic,
  )
}

fn decode(
  text: String,
) -> Result(aquamarine_codec.Incoming, aquamarine_codec.DecodeError) {
  case roost_frame.decode(text) {
    Ok(incoming) ->
      Ok(aquamarine_codec.Incoming(
        join_ref: incoming.join_ref,
        ref: incoming.ref,
        topic: incoming.topic,
        event: incoming.event,
        payload: incoming.payload,
      ))
    Error(error) -> Error(decode_error(error))
  }
}

fn matches_reply(
  incoming: aquamarine_codec.Incoming,
  join_ref: String,
) -> Bool {
  roost_frame.matches_join_reply(to_roost(incoming), join_ref)
}

fn reply_status(incoming: aquamarine_codec.Incoming) -> Result(Nil, String) {
  roost_frame.reply_status(to_roost(incoming))
}

fn to_roost(incoming: aquamarine_codec.Incoming) -> roost_frame.Incoming {
  roost_frame.Incoming(
    join_ref: incoming.join_ref,
    ref: incoming.ref,
    topic: incoming.topic,
    event: incoming.event,
    payload: incoming.payload,
  )
}

fn encode_join(ref: String, topic: String, payload: json.Json) -> String {
  roost_frame.encode(
    join_ref: Some(ref),
    ref: Some(ref),
    topic: topic,
    event: roost_frame.join_event,
    payload: payload,
  )
}

fn encode_push(
  join_ref: String,
  ref: String,
  topic: String,
  event: String,
  payload: json.Json,
) -> String {
  roost_frame.encode(
    join_ref: Some(join_ref),
    ref: Some(ref),
    topic: topic,
    event: event,
    payload: payload,
  )
}

fn decode_error(
  error: roost_frame.DecodeError,
) -> aquamarine_codec.DecodeError {
  case error {
    roost_frame.InvalidJson(reason) -> aquamarine_codec.InvalidJson(reason)
    roost_frame.InvalidFormat(reason) -> aquamarine_codec.InvalidFormat(reason)
  }
}
