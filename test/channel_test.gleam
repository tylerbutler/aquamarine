//// Branch-coverage tests for `aquamarine/channel` using an in-memory
//// transport.
////
//// These tests exercise paths that the integration test cannot reach
//// without standing up a misbehaving server: join rejections, malformed
//// replies, decode failures, transport errors, and the various inbound
//// frame classes that `receive` must skip or terminate on.

import aquamarine/channel
import aquamarine/codec
import aquamarine/error
import aquamarine/phoenix
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import roost/frame as roost_frame
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

// -- channel.connect_with ---------------------------------------------------

pub fn connect_with_returns_ok_on_a_matching_ok_join_reply_test() {
  let f = fake.start()
  let ch = connect_with_fake(f)

  // The very first outbound frame must be the join.
  let assert [join_frame, ..] = fake.outbound(f)
  let assert Ok(decoded) = phoenix.codec().decode(join_frame)
  assert decoded.event == roost_frame.join_event
  assert decoded.topic == test_topic

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

pub fn connect_with_maps_a_non_ok_status_to_join_rejected_test() {
  let f = fake.start()
  fake.enqueue_text(f, error_join_reply("1"))

  assert channel.connect_with(
      fake.connector_for(f),
      test_topic,
      empty_payload(),
      phoenix.codec(),
      no_heartbeat,
    )
    == Error(error.JoinRejected("error"))

  // Cleanup must close the underlying transport.
  assert fake.is_closed(f)
  fake.shutdown(f)
}

pub fn connect_with_maps_a_malformed_reply_payload_to_join_rejected_test() {
  let f = fake.start()
  fake.enqueue_text(f, malformed_reply("1"))

  assert channel.connect_with(
      fake.connector_for(f),
      test_topic,
      empty_payload(),
      phoenix.codec(),
      no_heartbeat,
    )
    == Error(error.JoinRejected("error"))

  assert fake.is_closed(f)
  fake.shutdown(f)
}

pub fn connect_with_maps_undecodable_reply_text_to_decode_failed_test() {
  let f = fake.start()
  fake.enqueue_text(f, "this is not valid json")

  let assert Error(error.DecodeFailed(_)) =
    channel.connect_with(
      fake.connector_for(f),
      test_topic,
      empty_payload(),
      phoenix.codec(),
      no_heartbeat,
    )

  assert fake.is_closed(f)
  fake.shutdown(f)
}

pub fn connect_with_maps_a_closed_frame_during_handshake_to_channel_closed_test() {
  let f = fake.start()
  fake.enqueue_closed(f)

  assert channel.connect_with(
      fake.connector_for(f),
      test_topic,
      empty_payload(),
      phoenix.codec(),
      no_heartbeat,
    )
    == Error(error.ChannelClosed)

  assert fake.is_closed(f)
  fake.shutdown(f)
}

pub fn connect_with_propagates_a_send_side_error_on_the_join_frame_test() {
  let f = fake.start()
  fake.enqueue_send_error(f, error.Transport(error.Timeout))

  assert channel.connect_with(
      fake.connector_for(f),
      test_topic,
      empty_payload(),
      phoenix.codec(),
      no_heartbeat,
    )
    == Error(error.Transport(error.Timeout))

  assert fake.is_closed(f)
  fake.shutdown(f)
}

/// Regression test for the dropped-frame bug.
///
/// Under the old blocking `receive`, `await_join_reply` decoded every frame
/// that was not the join reply and then discarded it by recursing — so a
/// server push that arrived before the reply was silently lost. The socket
/// actor has somewhere to put it: the events subject.
pub fn a_push_arriving_before_the_join_reply_is_delivered_not_dropped_test() {
  let f = fake.start()

  // The server pushes first, and only then answers the join.
  fake.enqueue_text(
    f,
    roost_frame.encode(
      join_ref: None,
      ref: None,
      topic: test_topic,
      event: "early",
      payload: json.object([#("n", json.int(1))]),
    ),
  )
  fake.enqueue_text(f, ok_join_reply("1"))

  let assert Ok(ch) =
    channel.connect_with(
      fake.connector_for(f),
      test_topic,
      empty_payload(),
      phoenix.codec(),
      no_heartbeat,
    )

  let assert Ok(incoming) = channel.receive(ch)
  assert incoming.event == "early"
  assert decode_n(incoming.payload) == Ok(1)

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

pub fn connect_with_skips_non_matching_frames_before_the_join_reply_test() {
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
}

pub fn connect_with_propagates_a_connector_failure_verbatim_test() {
  let connector =
    fake.failing_connector(error.Transport(error.ConnectionError("nope")))

  assert channel.connect_with(
      connector,
      test_topic,
      empty_payload(),
      phoenix.codec(),
      no_heartbeat,
    )
    == Error(error.Transport(error.ConnectionError("nope")))
}

// -- channel.push -----------------------------------------------------------

pub fn push_encodes_the_topic_event_payload_and_a_fresh_ref_test() {
  let f = fake.start()
  let ch = connect_with_fake(f)

  channel.push(ch, "say", json.object([#("body", json.string("hi"))]))

  // Push is fire-and-forget, so wait for the socket actor to hand the frame
  // to the transport before asserting on it.
  process.sleep(20)

  // outbound: [join, push]
  let assert [_, push_frame] = fake.outbound(f)
  let assert Ok(decoded) = phoenix.codec().decode(push_frame)
  assert decoded.topic == test_topic
  assert decoded.event == "say"
  assert decoded.join_ref == Some("1")
  // Join consumed ref 1; the next allocation is "2".
  assert decoded.ref == Some("2")

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

pub fn push_surfaces_a_transport_send_failure_on_the_next_receive_test() {
  let f = fake.start()
  let ch = connect_with_fake(f)

  fake.enqueue_send_error(f, error.Transport(error.ConnectionDown("gone")))

  // `push` cannot report the failure itself — it is fire-and-forget. A send
  // that fails takes the socket down, and that is what the caller observes.
  channel.push(ch, "say", empty_payload())

  assert channel.receive(ch)
    == Error(error.Transport(error.ConnectionDown("gone")))

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

// -- refs -------------------------------------------------------------------

/// Refs are minted inside the socket actor, in the same message handler that
/// sends the frame carrying them. That is what makes this assertion possible:
/// under the old design a ref was obtained and the frame sent in two steps
/// from two different processes, so ref order and send order could diverge.
pub fn refs_are_monotonic_unique_and_assigned_in_send_order_test() {
  let f = fake.start()
  let ch = connect_with_fake(f)

  channel.push(ch, "one", empty_payload())
  channel.push(ch, "two", empty_payload())
  channel.push(ch, "three", empty_payload())
  process.sleep(20)

  let assert [join_frame, first, second, third] = fake.outbound(f)

  assert ref_of(join_frame) == Some("1")
  assert ref_of(first) == Some("2")
  assert ref_of(second) == Some("3")
  assert ref_of(third) == Some("4")

  // Order of refs matches order of events, not just order of allocation.
  assert event_of(first) == "one"
  assert event_of(second) == "two"
  assert event_of(third) == "three"

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

/// Heartbeats draw on the same counter as pushes — there is only one.
pub fn heartbeat_frames_share_the_sockets_ref_sequence_test() {
  let f = fake.start()
  let ch = connect_with_beating_fake(f, 20)

  channel.push(ch, "one", empty_payload())
  process.sleep(60)

  let assert [_join, push_frame, heartbeat_frame, ..] = fake.outbound(f)
  assert ref_of(push_frame) == Some("2")
  assert event_of(heartbeat_frame) == "heartbeat"
  assert ref_of(heartbeat_frame) == Some("3")

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

// -- heartbeat --------------------------------------------------------------

pub fn heartbeats_are_emitted_on_the_configured_interval_test() {
  let f = fake.start()
  let ch = connect_with_beating_fake(f, 20)

  process.sleep(110)
  let beats = heartbeat_frames(f)

  // Four intervals fit in 110ms; allow slack either side for scheduler jitter.
  assert beats >= 3
  assert beats <= 6

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

/// The timer must not outlive the socket. Nothing cancels it from outside —
/// the actor cancels its own pending tick on the way down.
pub fn no_heartbeat_frames_are_sent_after_close_test() {
  let f = fake.start()
  let ch = connect_with_beating_fake(f, 20)

  process.sleep(50)
  let assert Ok(Nil) = channel.close(ch)
  let at_close = heartbeat_frames(f)
  assert at_close > 0

  process.sleep(100)
  assert heartbeat_frames(f) == at_close

  fake.shutdown(f)
}

/// The heartbeat's own replies are bookkeeping and never reach the caller.
pub fn heartbeat_replies_never_surface_to_receive_test() {
  let f = fake.start()
  let ch = connect_with_beating_fake(f, 20)

  // Answer whatever heartbeats have gone out, then send a real frame.
  process.sleep(50)
  fake.enqueue_text(
    f,
    roost_frame.encode_reply(
      join_ref: None,
      ref: "2",
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
      event: "real",
      payload: empty_payload(),
    ),
  )

  let assert Ok(incoming) = channel.receive(ch)
  assert incoming.event == "real"

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

/// Connect through a fake with a short heartbeat interval.
fn connect_with_beating_fake(
  fake_socket: fake.FakeSocket,
  interval_ms: Int,
) -> channel.Channel {
  fake.enqueue_text(fake_socket, ok_join_reply("1"))
  let assert Ok(ch) =
    channel.connect_with(
      fake.connector_for(fake_socket),
      test_topic,
      empty_payload(),
      phoenix.codec(),
      interval_ms,
    )
  ch
}

fn heartbeat_frames(f: fake.FakeSocket) -> Int {
  fake.outbound(f)
  |> list.filter(fn(frame) { event_of(frame) == "heartbeat" })
  |> list.length
}

fn ref_of(frame: String) -> option.Option(String) {
  let assert Ok(decoded) = phoenix.codec().decode(frame)
  decoded.ref
}

fn event_of(frame: String) -> String {
  let assert Ok(decoded) = phoenix.codec().decode(frame)
  decoded.event
}

// -- channel.push_and_await_reply -------------------------------------------

pub fn push_and_await_reply_returns_the_matching_reply_test() {
  let f = fake.start()
  let ch = connect_with_fake(f)

  // The push will go out under ref "2"; answer it.
  spawn_reply(f, "2", json.object([#("pong", json.bool(True))]))

  let assert Ok(incoming) =
    channel.push_and_await_reply(ch, "ping", empty_payload(), 500)
  assert incoming.ref == Some("2")
  assert incoming.event == roost_frame.reply_event

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

/// Two processes push at once. Each must get its own reply, not the other's —
/// which is the thing a single blocking `receive` could not do.
pub fn concurrent_pushes_each_get_their_own_reply_test() {
  let f = fake.start()
  let ch = connect_with_fake(f)
  let results = process.new_subject()

  process.spawn(fn() {
    process.send(results, #(
      "a",
      channel.push_and_await_reply(ch, "a", empty_payload(), 1000),
    ))
  })
  process.spawn(fn() {
    process.send(results, #(
      "b",
      channel.push_and_await_reply(ch, "b", empty_payload(), 1000),
    ))
  })

  // Let both register, then answer both refs out of order.
  process.sleep(30)
  reply_to_ref(f, "3", json.object([#("who", json.string("three"))]))
  reply_to_ref(f, "2", json.object([#("who", json.string("two"))]))

  let assert Ok(#(_, first)) = process.receive(results, 1000)
  let assert Ok(#(_, second)) = process.receive(results, 1000)

  // Whichever order they finish in, each reply carries the ref it asked for.
  let assert Ok(one) = first
  let assert Ok(two) = second
  assert one.ref != two.ref
  assert reply_who(one) == expected_who(one)
  assert reply_who(two) == expected_who(two)

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

pub fn frames_arriving_between_a_push_and_its_reply_reach_the_subscriber_test() {
  let f = fake.start()
  let ch = connect_with_fake(f)

  process.spawn(fn() {
    // Unrelated server push first, then the reply the caller is waiting on.
    process.sleep(20)
    fake.enqueue_text(
      f,
      roost_frame.encode(
        join_ref: None,
        ref: None,
        topic: test_topic,
        event: "interleaved",
        payload: empty_payload(),
      ),
    )
    reply_to_ref(f, "2", empty_payload())
  })

  let assert Ok(_) =
    channel.push_and_await_reply(ch, "ping", empty_payload(), 1000)

  // The interleaved frame was not dropped to make room for the reply.
  let assert Ok(incoming) = channel.receive(ch)
  assert incoming.event == "interleaved"

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

/// A caller that gives up must not leave an entry behind. Observable: the late
/// reply falls through to the subscriber instead of being swallowed by a stale
/// pending entry.
pub fn a_reply_timeout_drops_the_pending_entry_test() {
  let f = fake.start()
  let ch = connect_with_fake(f)

  assert channel.push_and_await_reply(ch, "ping", empty_payload(), 50)
    == Error(error.ReplyTimeout)

  // Give the cancel a moment to land, then deliver the late reply.
  process.sleep(20)
  reply_to_ref(f, "2", empty_payload())

  let assert Ok(incoming) = channel.receive(ch)
  assert incoming.ref == Some("2")

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

pub fn losing_the_socket_fails_every_pending_waiter_test() {
  let f = fake.start()
  let ch = connect_with_fake(f)
  let results = process.new_subject()

  process.spawn(fn() {
    process.send(
      results,
      channel.push_and_await_reply(ch, "a", empty_payload(), 5000),
    )
  })
  process.spawn(fn() {
    process.send(
      results,
      channel.push_and_await_reply(ch, "b", empty_payload(), 5000),
    )
  })

  process.sleep(30)
  fake.enqueue_closed(f)

  // Both waiters are failed promptly — neither runs to its 5s timeout.
  assert process.receive(results, 500) == Ok(Error(error.ChannelClosed))
  assert process.receive(results, 500) == Ok(Error(error.ChannelClosed))

  fake.shutdown(f)
}

/// A codec that cannot correlate — `matches_reply` always False — must not
/// hang a caller. It degrades to "no reply available" at the timeout.
pub fn a_codec_that_cannot_correlate_degrades_to_reply_timeout_test() {
  let f = fake.start()
  let codec = uncorrelating_codec()

  fake.enqueue_text(f, ok_join_reply("1"))
  // The join itself cannot correlate either, so connect times out rather than
  // blocking forever.
  assert channel.connect_with(
      fake.connector_for(f),
      test_topic,
      empty_payload(),
      codec,
      no_heartbeat,
    )
    == Error(error.ReplyTimeout)

  fake.shutdown(f)
}

// -- #8: the accepted join reply --------------------------------------------

pub fn connect_exposes_the_accepted_join_reply_test() {
  let f = fake.start()
  fake.enqueue_text(
    f,
    roost_frame.encode_reply(
      join_ref: Some("1"),
      ref: "1",
      topic: test_topic,
      status: roost_frame.StatusOk,
      response: json.object([#("n", json.int(99))]),
    ),
  )
  let assert Ok(ch) =
    channel.connect_with(
      fake.connector_for(f),
      test_topic,
      empty_payload(),
      phoenix.codec(),
      no_heartbeat,
    )

  let reply = channel.join_reply(ch)
  assert reply.topic == test_topic
  assert reply.event == roost_frame.reply_event
  assert decode_response_n(reply.payload) == Ok(99)

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

// -- helpers for reply correlation ------------------------------------------

/// Deliver a `phx_reply` for `ref` immediately.
fn reply_to_ref(f: fake.FakeSocket, ref: String, response: json.Json) -> Nil {
  fake.enqueue_text(
    f,
    roost_frame.encode_reply(
      join_ref: Some("1"),
      ref: ref,
      topic: test_topic,
      status: roost_frame.StatusOk,
      response: response,
    ),
  )
}

/// Deliver a reply once the caller has had a chance to register.
fn spawn_reply(f: fake.FakeSocket, ref: String, response: json.Json) -> Nil {
  process.spawn(fn() {
    process.sleep(20)
    reply_to_ref(f, ref, response)
  })
  Nil
}

fn reply_who(incoming: codec.Incoming) -> Result(String, Nil) {
  decode.run(incoming.payload, decode.at(["response", "who"], decode.string))
  |> result.map_error(fn(_) { Nil })
}

/// Refs "2" and "3" were answered with "two" and "three" respectively.
fn expected_who(incoming: codec.Incoming) -> Result(String, Nil) {
  case incoming.ref {
    Some("2") -> Ok("two")
    Some("3") -> Ok("three")
    _ -> Error(Nil)
  }
}

fn decode_response_n(payload) -> Result(Int, Nil) {
  let decoder = {
    use n <- decode.field("response", decode.at(["n"], decode.int))
    decode.success(n)
  }
  decode.run(payload, decoder)
  |> result.map_error(fn(_) { Nil })
}

/// A codec identical to Phoenix's except that it can never decide whether a
/// frame is the reply to a given ref.
fn uncorrelating_codec() -> codec.Codec {
  let base = phoenix.codec()
  codec.Codec(..base, matches_reply: fn(_incoming, _ref) { False })
}

// -- channel.receive --------------------------------------------------------

pub fn receive_returns_the_next_application_frame_test() {
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
  assert incoming.event == "tick"
  assert incoming.topic == test_topic
  assert decode_n(incoming.payload) == Ok(7)

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

pub fn receive_skips_a_binary_frame_and_returns_the_next_text_frame_test() {
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
  assert incoming.event == "after_binary"

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

pub fn receive_skips_a_heartbeat_reply_and_returns_the_next_channel_frame_test() {
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
  assert incoming.event == "after_hb"

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

pub fn receive_returns_channel_closed_on_a_phx_close_event_test() {
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

  assert channel.receive(ch) == Error(error.ChannelClosed)

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

pub fn receive_returns_channel_closed_on_a_phx_error_event_test() {
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

  assert channel.receive(ch) == Error(error.ChannelClosed)

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

pub fn receive_returns_channel_closed_on_a_closed_frame_test() {
  let f = fake.start()
  let ch = connect_with_fake(f)

  fake.enqueue_closed(f)

  assert channel.receive(ch) == Error(error.ChannelClosed)

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

pub fn receive_returns_decode_failed_on_a_malformed_text_frame_test() {
  let f = fake.start()
  let ch = connect_with_fake(f)

  fake.enqueue_text(f, "not json")

  let assert Error(error.DecodeFailed(_)) = channel.receive(ch)

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)
}

// -- channel.close ----------------------------------------------------------

pub fn close_closes_the_transport_and_stops_the_heartbeat_actor_test() {
  let f = fake.start()
  let ch = connect_with_fake(f)

  let assert Ok(Nil) = channel.close(ch)

  assert fake.is_closed(f)
  fake.shutdown(f)
}

pub fn close_propagates_a_transport_close_error_test() {
  let f = fake.start()
  let ch = connect_with_fake(f)

  fake.enqueue_close_error(
    f,
    error.Transport(error.ConnectionError("close failed")),
  )

  assert channel.close(ch)
    == Error(error.Transport(error.ConnectionError("close failed")))

  // Give the heartbeat/counter actors a tick to fully exit before the
  // fake socket is shut down.
  process.sleep(5)
  fake.shutdown(f)
}

fn decode_n(payload) -> Result(Int, Nil) {
  let decoder = {
    use n <- decode.field("n", decode.int)
    decode.success(n)
  }
  decode.run(payload, decoder)
  |> result.map_error(fn(_) { Nil })
}
