import aquamarine/codec as aquamarine_codec
import aquamarine/phoenix
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import phoenix_channel_fixtures/frame as fixtures
import startest.{describe, it}
import startest/expect

pub fn codec_tests() {
  describe("phoenix codec adapter", [
    it("encodes all shared client outbound fixtures", fn() {
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

        encoded |> expect.to_equal(case_.encoded)
      })
    }),
    it("decodes all shared inbound fixtures", fn() {
      let codec = phoenix.codec()

      fixtures.inbound_common()
      |> list.each(fn(case_) {
        let assert Ok(incoming) = codec.decode(case_.encoded)
        incoming.join_ref |> expect.to_equal(case_.join_ref)
        incoming.ref |> expect.to_equal(case_.ref)
        incoming.topic |> expect.to_equal(case_.topic)
        incoming.event |> expect.to_equal(case_.event)
        assert_payload_matches(incoming.payload, case_.payload)
      })
    }),
    it("classifies all shared invalid frame fixtures", fn() {
      let codec = phoenix.codec()

      fixtures.invalid_frames()
      |> list.each(fn(case_) {
        codec.decode(case_.encoded)
        |> decode_error_reason
        |> expect.to_equal(Ok(case_.reason))
      })
    }),
    it("exposes phoenix system event names", fn() {
      let codec = phoenix.codec()
      codec.join_event |> expect.to_equal(fixtures.join_event)
      codec.reply_event |> expect.to_equal(fixtures.reply_event)
      codec.close_event |> expect.to_equal(fixtures.close_event)
      codec.error_event |> expect.to_equal(fixtures.error_event)
      codec.heartbeat_topic |> expect.to_equal(fixtures.heartbeat_topic)
    }),
    it("matches a join reply by ref and reads its status", fn() {
      let codec = phoenix.codec()
      let reply =
        incoming(ref: Some("7"), event: fixtures.reply_event, status: "ok")

      codec.matches_reply(reply, "7") |> expect.to_equal(True)
      codec.matches_reply(reply, "8") |> expect.to_equal(False)
      codec.reply_status(reply) |> expect.to_equal(Ok(Nil))
    }),
    it("correlates a refless reply via matches_reply", fn() {
      let refless = refless_codec()
      let reply =
        incoming(ref: None, event: "connect_document_success", status: "ok")

      refless.matches_reply(reply, "ignored") |> expect.to_equal(True)
      refless.reply_status(reply) |> expect.to_equal(Ok(Nil))
    }),
  ])
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

  decode.run(actual, decode.dynamic)
  |> expect.to_equal(Ok(expected_dynamic))
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
