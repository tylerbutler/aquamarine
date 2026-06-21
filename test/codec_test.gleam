import aquamarine/codec as aquamarine_codec
import aquamarine/phoenix
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{Some}
import phoenix_channel_fixtures/frame as fixtures
import gleeunit/should

pub fn codec_tests_test() {
  // encodes all shared client outbound fixtures
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

    encoded |> should.equal(case_.encoded)
  })

  // decodes all shared inbound fixtures
  let codec = phoenix.codec()
  fixtures.inbound_common()
  |> list.each(fn(case_) {
    let assert Ok(incoming) = codec.decode(case_.encoded)
    incoming.join_ref |> should.equal(case_.join_ref)
    incoming.ref |> should.equal(case_.ref)
    incoming.topic |> should.equal(case_.topic)
    incoming.event |> should.equal(case_.event)
    assert_payload_matches(incoming.payload, case_.payload)
  })

  // classifies all shared invalid frame fixtures
  let codec = phoenix.codec()
  fixtures.invalid_frames()
  |> list.each(fn(case_) {
    codec.decode(case_.encoded)
    |> decode_error_reason
    |> should.equal(Ok(case_.reason))
  })

  // exposes phoenix system event names
  let codec = phoenix.codec()
  codec.join_event |> should.equal(fixtures.join_event)
  codec.reply_event |> should.equal(fixtures.reply_event)
  codec.close_event |> should.equal(fixtures.close_event)
  codec.error_event |> should.equal(fixtures.error_event)
  codec.heartbeat_topic |> should.equal(fixtures.heartbeat_topic)
}

fn assert_payload_matches(actual: Dynamic, expected: json.Json) {
  let assert Ok(expected_dynamic) =
    json.parse(json.to_string(expected), decode.dynamic)

  decode.run(actual, decode.dynamic)
  |> should.equal(Ok(expected_dynamic))
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
