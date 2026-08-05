import aquamarine/codec as aquamarine_codec
import aquamarine/phoenix
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import phoenix_channel_fixtures/frame as fixtures

pub fn encodes_all_shared_client_outbound_fixtures_test() {
  let codec = phoenix.codec()

  fixtures.client_outbound()
  |> list.each(fn(case_) {
    let encoded = case
      case_.event == fixtures.join_event,
      case_.event == fixtures.heartbeat_event
    {
      True, _ -> {
        let assert Some(ref) = case_.ref
        codec.encode_join(ref, case_.topic, case_.payload)
      }
      _, True -> {
        let assert Some(ref) = case_.ref
        codec.encode_heartbeat(ref)
      }
      False, False -> {
        let assert Some(join_ref) = case_.join_ref
        let assert Some(ref) = case_.ref
        codec.encode_push(
          join_ref,
          ref,
          case_.topic,
          case_.event,
          case_.payload,
        )
      }
    }

    assert encoded == case_.encoded
  })
}

pub fn decodes_all_shared_inbound_fixtures_test() {
  let codec = phoenix.codec()

  fixtures.inbound_common()
  |> list.each(fn(case_) {
    let assert Ok(incoming) = codec.decode(case_.encoded)
    assert incoming.join_ref == case_.join_ref
    assert incoming.ref == case_.ref
    assert incoming.topic == case_.topic
    assert incoming.event == case_.event
    assert_payload_matches(incoming.payload, case_.payload)
  })
}

pub fn classifies_all_shared_invalid_frame_fixtures_test() {
  let codec = phoenix.codec()

  fixtures.invalid_frames()
  |> list.each(fn(case_) {
    assert decode_error_reason(codec.decode(case_.encoded)) == Ok(case_.reason)
  })
}

pub fn exposes_phoenix_system_event_names_test() {
  let codec = phoenix.codec()
  assert codec.join_event == fixtures.join_event
  assert codec.reply_event == fixtures.reply_event
  assert codec.close_event == fixtures.close_event
  assert codec.error_event == fixtures.error_event
  assert codec.heartbeat_topic == fixtures.heartbeat_topic
}

pub fn matches_a_join_reply_by_ref_and_reads_its_status_test() {
  let codec = phoenix.codec()
  let reply =
    incoming(ref: Some("7"), event: fixtures.reply_event, status: "ok")

  assert codec.matches_reply(reply, "7")
  assert !codec.matches_reply(reply, "8")
  assert codec.reply_status(reply) == Ok(Nil)
}

pub fn correlates_a_refless_reply_via_matches_reply_test() {
  let refless = refless_codec()
  let reply =
    incoming(ref: None, event: "connect_document_success", status: "ok")

  assert refless.matches_reply(reply, "ignored")
  assert refless.reply_status(reply) == Ok(Nil)
}

/// Codec for a refless protocol: correlates a join reply purely by event name.
fn refless_codec() -> aquamarine_codec.Codec {
  let phx = phoenix.codec()
  aquamarine_codec.Codec(
    ..phx,
    matches_reply: fn(in: aquamarine_codec.Incoming, _jr) {
      in.event == "connect_document_success"
    },
    reply_status: fn(_in) { Ok(Nil) },
  )
}

fn incoming(
  ref ref: option.Option(String),
  event event: String,
  status status: String,
) -> aquamarine_codec.Incoming {
  let assert Ok(payload) =
    json.parse(
      json.to_string(json.object([#("status", json.string(status))])),
      decode.dynamic,
    )
  aquamarine_codec.Incoming(
    join_ref: ref,
    ref: ref,
    topic: "t",
    event: event,
    payload: payload,
  )
}

fn assert_payload_matches(actual: Dynamic, expected: json.Json) {
  let assert Ok(expected_dynamic) =
    json.parse(json.to_string(expected), decode.dynamic)

  assert decode.run(actual, decode.dynamic) == Ok(expected_dynamic)
}

fn decode_error_reason(
  result: Result(aquamarine_codec.Incoming, aquamarine_codec.DecodeError),
) -> Result(fixtures.InvalidReason, Nil) {
  case result {
    Error(aquamarine_codec.InvalidJson(_)) -> Ok(fixtures.InvalidJson)
    Error(aquamarine_codec.InvalidFormat(_)) -> Ok(fixtures.InvalidFormat)
    Ok(_) -> Error(Nil)
  }
}
