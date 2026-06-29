//// Branch-coverage tests for `aquamarine/channel` using an in-memory
//// transport.
////
//// These tests exercise paths that the integration test cannot reach
//// without standing up a misbehaving server: join rejections, malformed
//// replies, decode failures, transport errors, and the various inbound
//// frame classes that `receive` must skip or terminate on.

import aquamarine/channel
import aquamarine/error
import aquamarine/phoenix
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import roost/frame as roost_frame
import startest.{describe, it}
import startest/expect
import support/fake_transport as fake

// 24 hours — long enough that no test in this file ever sees a heartbeat tick.
const no_heartbeat: Int = 86_400_000

const test_topic: String = "test:lobby"

// -- Helpers ----------------------------------------------------------------

fn empty_payload() -> json.Json {
  json.object([])
}

/// Build an `ok` join reply for the given join_ref.
fn ok_join_reply(join_ref: String) -> String {
  roost_frame.encode_reply(
    join_ref: Some(join_ref),
    ref: join_ref,
    topic: test_topic,
    status: roost_frame.StatusOk,
    response: empty_payload(),
  )
}

/// Build an `error` join reply for the given join_ref.
fn error_join_reply(join_ref: String) -> String {
  roost_frame.encode_reply(
    join_ref: Some(join_ref),
    ref: join_ref,
    topic: test_topic,
    status: roost_frame.StatusError,
    response: empty_payload(),
  )
}

/// Build a `phx_reply` whose payload is missing the `status` field.
fn malformed_reply(join_ref: String) -> String {
  roost_frame.encode(
    join_ref: Some(join_ref),
    ref: Some(join_ref),
    topic: test_topic,
    event: roost_frame.reply_event,
    payload: json.object([#("response", empty_payload())]),
  )
}

/// Connect a channel through a fake socket, scripting a successful join
/// reply on whatever ref is allocated first (always `"1"` from a fresh
/// `ref.start`).
fn connect_with_fake(fake_socket: fake.FakeSocket) -> channel.Channel {
  fake.enqueue_text(fake_socket, ok_join_reply("1"))
  let assert Ok(ch) =
    channel.connect_with(
      fake.connector_for(fake_socket),
      test_topic,
      empty_payload(),
      phoenix.codec(),
      no_heartbeat,
    )
  ch
}

// -- Tests ------------------------------------------------------------------

pub fn channel_tests() {
  describe("channel", [
    describe("channel.connect_with", [
      it("returns Ok on a matching ok join reply", fn() {
        let f = fake.start()
        let ch = connect_with_fake(f)

        // The very first outbound frame must be the join.
        let assert [join_frame, ..] = fake.outbound(f)
        let assert Ok(decoded) = phoenix.codec().decode(join_frame)
        decoded.event |> expect.to_equal(roost_frame.join_event)
        decoded.topic |> expect.to_equal(test_topic)

        let assert Ok(Nil) = channel.close(ch)
        fake.shutdown(f)
      }),
      it("maps a non-ok status to JoinRejected", fn() {
        let f = fake.start()
        fake.enqueue_text(f, error_join_reply("1"))

        channel.connect_with(
          fake.connector_for(f),
          test_topic,
          empty_payload(),
          phoenix.codec(),
          no_heartbeat,
        )
        |> expect.to_equal(Error(error.JoinRejected("error")))

        // Cleanup must close the underlying transport.
        fake.is_closed(f) |> expect.to_equal(True)
        fake.shutdown(f)
      }),
      it("maps a malformed reply payload to JoinRejected(\"error\")", fn() {
        let f = fake.start()
        fake.enqueue_text(f, malformed_reply("1"))

        channel.connect_with(
          fake.connector_for(f),
          test_topic,
          empty_payload(),
          phoenix.codec(),
          no_heartbeat,
        )
        |> expect.to_equal(Error(error.JoinRejected("error")))

        fake.is_closed(f) |> expect.to_equal(True)
        fake.shutdown(f)
      }),
      it("maps undecodable text on the reply channel to DecodeFailed", fn() {
        let f = fake.start()
        fake.enqueue_text(f, "this is not valid json")

        let result =
          channel.connect_with(
            fake.connector_for(f),
            test_topic,
            empty_payload(),
            phoenix.codec(),
            no_heartbeat,
          )

        case result {
          Error(error.DecodeFailed(_)) -> Nil
          other -> {
            other
            |> expect.to_equal(
              Error(error.DecodeFailed(
                // Force a mismatch with detailed diff if this branch ever fires.
                phoenix.codec().decode("[")
                |> fn(r) {
                  case r {
                    Error(e) -> e
                    Ok(_) -> panic as "decoder unexpectedly succeeded"
                  }
                },
              )),
            )
          }
        }

        fake.is_closed(f) |> expect.to_equal(True)
        fake.shutdown(f)
      }),
      it("maps a Closed frame during handshake to ChannelClosed", fn() {
        let f = fake.start()
        fake.enqueue_closed(f)

        channel.connect_with(
          fake.connector_for(f),
          test_topic,
          empty_payload(),
          phoenix.codec(),
          no_heartbeat,
        )
        |> expect.to_equal(Error(error.ChannelClosed))

        fake.is_closed(f) |> expect.to_equal(True)
        fake.shutdown(f)
      }),
      it("propagates a send-side error on the join frame and cleans up", fn() {
        let f = fake.start()
        fake.enqueue_send_error(f, error.Transport(error.Timeout))

        channel.connect_with(
          fake.connector_for(f),
          test_topic,
          empty_payload(),
          phoenix.codec(),
          no_heartbeat,
        )
        |> expect.to_equal(Error(error.Transport(error.Timeout)))

        fake.is_closed(f) |> expect.to_equal(True)
        fake.shutdown(f)
      }),
      it("skips non-matching frames before the join reply", fn() {
        let f = fake.start()
        // Some unrelated server push arrives before the reply for ref "1".
        fake.enqueue_text(
          f,
          roost_frame.encode(
            join_ref: None,
            ref: None,
            topic: test_topic,
            event: "noise",
            payload: empty_payload(),
          ),
        )
        // Then a binary frame which the codec also skips.
        fake.enqueue_binary(f, <<1, 2, 3>>)
        // Finally the actual join reply.
        fake.enqueue_text(f, ok_join_reply("1"))

        let assert Ok(ch) =
          channel.connect_with(
            fake.connector_for(f),
            test_topic,
            empty_payload(),
            phoenix.codec(),
            no_heartbeat,
          )
        let assert Ok(Nil) = channel.close(ch)
        fake.shutdown(f)
      }),
      it("propagates a connector failure verbatim", fn() {
        let connector =
          fake.failing_connector(error.Transport(error.ConnectionError("nope")))
        channel.connect_with(
          connector,
          test_topic,
          empty_payload(),
          phoenix.codec(),
          no_heartbeat,
        )
        |> expect.to_equal(
          Error(error.Transport(error.ConnectionError("nope"))),
        )
      }),
    ]),
    describe("channel.push", [
      it("encodes the topic, event, payload, and a fresh ref", fn() {
        let f = fake.start()
        let ch = connect_with_fake(f)

        let assert Ok(Nil) =
          channel.push(ch, "say", json.object([#("body", json.string("hi"))]))

        // outbound: [join, push]
        let assert [_, push_frame] = fake.outbound(f)
        let assert Ok(decoded) = phoenix.codec().decode(push_frame)
        decoded.topic |> expect.to_equal(test_topic)
        decoded.event |> expect.to_equal("say")
        decoded.join_ref |> expect.to_equal(Some("1"))
        // Join consumed ref 1; the next allocation is "2".
        decoded.ref |> expect.to_equal(Some("2"))

        let assert Ok(Nil) = channel.close(ch)
        fake.shutdown(f)
      }),
      it("maps a transport send failure to the underlying error", fn() {
        let f = fake.start()
        let ch = connect_with_fake(f)

        fake.enqueue_send_error(
          f,
          error.Transport(error.ConnectionDown("gone")),
        )

        channel.push(ch, "say", empty_payload())
        |> expect.to_equal(Error(error.Transport(error.ConnectionDown("gone"))))

        let assert Ok(Nil) = channel.close(ch)
        fake.shutdown(f)
      }),
    ]),
    describe("channel.receive", [
      it("returns the next application frame", fn() {
        let f = fake.start()
        let ch = connect_with_fake(f)

        let server_push =
          roost_frame.encode(
            join_ref: None,
            ref: None,
            topic: test_topic,
            event: "tick",
            payload: json.object([#("n", json.int(7))]),
          )
        fake.enqueue_text(f, server_push)

        let assert Ok(incoming) = channel.receive(ch)
        incoming.event |> expect.to_equal("tick")
        incoming.topic |> expect.to_equal(test_topic)
        decode_n(incoming.payload) |> expect.to_equal(Ok(7))

        let assert Ok(Nil) = channel.close(ch)
        fake.shutdown(f)
      }),
      it("skips a binary frame and returns the next text frame", fn() {
        let f = fake.start()
        let ch = connect_with_fake(f)

        fake.enqueue_binary(f, <<255, 0, 1>>)
        fake.enqueue_text(
          f,
          roost_frame.encode(
            join_ref: None,
            ref: None,
            topic: test_topic,
            event: "after_binary",
            payload: empty_payload(),
          ),
        )

        let assert Ok(incoming) = channel.receive(ch)
        incoming.event |> expect.to_equal("after_binary")

        let assert Ok(Nil) = channel.close(ch)
        fake.shutdown(f)
      }),
      it("skips a heartbeat reply and returns the next channel frame", fn() {
        let f = fake.start()
        let ch = connect_with_fake(f)

        // Heartbeat reply: phx_reply on the reserved heartbeat topic.
        fake.enqueue_text(
          f,
          roost_frame.encode_reply(
            join_ref: None,
            ref: "99",
            topic: roost_frame.heartbeat_topic,
            status: roost_frame.StatusOk,
            response: empty_payload(),
          ),
        )
        fake.enqueue_text(
          f,
          roost_frame.encode(
            join_ref: None,
            ref: None,
            topic: test_topic,
            event: "after_hb",
            payload: empty_payload(),
          ),
        )

        let assert Ok(incoming) = channel.receive(ch)
        incoming.event |> expect.to_equal("after_hb")

        let assert Ok(Nil) = channel.close(ch)
        fake.shutdown(f)
      }),
      it("returns ChannelClosed on a phx_close event", fn() {
        let f = fake.start()
        let ch = connect_with_fake(f)

        fake.enqueue_text(
          f,
          roost_frame.encode(
            join_ref: None,
            ref: None,
            topic: test_topic,
            event: roost_frame.close_event,
            payload: empty_payload(),
          ),
        )

        channel.receive(ch) |> expect.to_equal(Error(error.ChannelClosed))

        let assert Ok(Nil) = channel.close(ch)
        fake.shutdown(f)
      }),
      it("returns ChannelClosed on a phx_error event", fn() {
        let f = fake.start()
        let ch = connect_with_fake(f)

        fake.enqueue_text(
          f,
          roost_frame.encode(
            join_ref: None,
            ref: None,
            topic: test_topic,
            event: roost_frame.error_event,
            payload: empty_payload(),
          ),
        )

        channel.receive(ch) |> expect.to_equal(Error(error.ChannelClosed))

        let assert Ok(Nil) = channel.close(ch)
        fake.shutdown(f)
      }),
      it("returns ChannelClosed on a Closed frame", fn() {
        let f = fake.start()
        let ch = connect_with_fake(f)

        fake.enqueue_closed(f)

        channel.receive(ch) |> expect.to_equal(Error(error.ChannelClosed))

        let assert Ok(Nil) = channel.close(ch)
        fake.shutdown(f)
      }),
      it("returns DecodeFailed on a malformed text frame", fn() {
        let f = fake.start()
        let ch = connect_with_fake(f)

        fake.enqueue_text(f, "not json")

        case channel.receive(ch) {
          Error(error.DecodeFailed(_)) -> Nil
          other ->
            other
            |> expect.to_equal(
              Error(error.DecodeFailed(
                // Force a clear mismatch if a non-DecodeFailed error sneaks in.
                phoenix.codec().decode("[")
                |> fn(r) {
                  case r {
                    Error(e) -> e
                    Ok(_) -> panic as "decoder unexpectedly succeeded"
                  }
                },
              )),
            )
        }

        let assert Ok(Nil) = channel.close(ch)
        fake.shutdown(f)
      }),
    ]),
    describe("channel.close", [
      it("closes the transport and stops the heartbeat actor", fn() {
        let f = fake.start()
        let ch = connect_with_fake(f)

        let assert Ok(Nil) = channel.close(ch)

        fake.is_closed(f) |> expect.to_equal(True)
        fake.shutdown(f)
      }),
      it("propagates a transport close error", fn() {
        let f = fake.start()
        let ch = connect_with_fake(f)

        fake.enqueue_close_error(
          f,
          error.Transport(error.ConnectionError("close failed")),
        )

        channel.close(ch)
        |> expect.to_equal(
          Error(error.Transport(error.ConnectionError("close failed"))),
        )

        // Give the heartbeat/counter actors a tick to fully exit before the
        // fake socket is shut down.
        process.sleep(5)
        fake.shutdown(f)
      }),
    ]),
  ])
}

fn decode_n(payload) -> Result(Int, Nil) {
  let decoder = {
    use n <- decode.field("n", decode.int)
    decode.success(n)
  }
  decode.run(payload, decoder)
  |> result.map_error(fn(_) { Nil })
}
