//// Reconnect with backoff and automatic rejoin.
////
//// The schedule is asserted as a pure function, so these tests never sleep
//// through a real backoff. Everything else runs on a schedule short enough to
//// finish in milliseconds.

import aquamarine/backoff
import aquamarine/channel
import aquamarine/error
import aquamarine/phoenix
import aquamarine/socket
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import roost/frame as roost_frame
import support/fake_transport as fake

const no_heartbeat: Int = 86_400_000

const topic_a: String = "test:a"

const topic_b: String = "test:b"

// -- the schedule -----------------------------------------------------------

/// No sleeping: the schedule is a pure function of the attempt number.
pub fn the_backoff_schedule_grows_and_then_caps_test() {
  let b = fixed_backoff()

  assert backoff.delay_ms(b, 1) == 100
  assert backoff.delay_ms(b, 2) == 200
  assert backoff.delay_ms(b, 3) == 400
  assert backoff.delay_ms(b, 4) == 800
  // Capped from here on.
  assert backoff.delay_ms(b, 5) == 1000
  assert backoff.delay_ms(b, 6) == 1000
  assert backoff.delay_ms(b, 50) == 1000
}

/// Jitter is a replaceable function, which is exactly why the schedule above
/// is assertable at all.
pub fn jitter_is_applied_to_the_capped_delay_test() {
  let b =
    fixed_backoff()
    |> backoff.with_jitter(fn(ms) { ms / 2 })

  assert backoff.delay_ms(b, 1) == 50
  assert backoff.delay_ms(b, 50) == 500
}

/// The default schedule jitters downward, so a fleet of clients does not
/// reconnect in lockstep. Assert the band rather than a value.
pub fn the_default_schedule_stays_within_its_bounds_test() {
  let b = backoff.default()

  list.repeat(0, 12)
  |> list.index_map(fn(_, i) { i + 1 })
  |> list.each(fn(attempt) {
    let delay = backoff.delay_ms(b, attempt)
    assert delay > 0
    assert delay <= 10_000
  })
}

pub fn retrying_forever_is_the_default_and_a_limit_can_be_set_test() {
  assert backoff.may_retry(backoff.default(), 1_000_000)

  let capped = backoff.default() |> backoff.with_max_attempts(3)
  assert backoff.may_retry(capped, 0)
  assert backoff.may_retry(capped, 2)
  assert !backoff.may_retry(capped, 3)
  assert !backoff.may_retry(capped, 4)

  assert backoff.may_retry(backoff.retrying_forever(capped), 99)
}

// -- reconnecting -----------------------------------------------------------

pub fn a_dropped_connection_reconnects_and_rejoins_test() {
  let f = fake.start()
  let sock = start_socket(f)
  let status = process.new_subject()
  socket.watch(sock, status)

  let a = join_ok(f, sock, topic_a, "1")

  // The rejoin goes out under a fresh ref; refs keep counting up.
  fake.enqueue_text_after(f, 30, ok_reply(topic_a, "2"))
  fake.enqueue_closed(f)

  let assert Ok(socket.Disconnected(error.ChannelClosed)) =
    process.receive(status, 500)
  let assert Ok(socket.Reconnecting(1, _)) = process.receive(status, 500)
  let assert Ok(socket.Connected) = process.receive(status, 1000)
  assert process.receive(status, 1000) == Ok(socket.Rejoined(topic_a))

  // The channel handle survived: same actor, same subject.
  fake.enqueue_text(f, server_push(topic_a, "after_reconnect"))
  let assert Ok(incoming) = channel.receive(a, 500)
  assert incoming.event == "after_reconnect"

  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

pub fn every_joined_topic_is_rejoined_test() {
  let f = fake.start()
  let sock = start_socket(f)
  let status = process.new_subject()
  socket.watch(sock, status)

  let _a = join_ok(f, sock, topic_a, "1")
  let _b = join_ok(f, sock, topic_b, "2")

  // Rejoins go out under refs 3 and 4, in topic order.
  fake.enqueue_text_after(f, 30, ok_reply(topic_a, "3"))
  fake.enqueue_text_after(f, 40, ok_reply(topic_b, "4"))
  fake.enqueue_closed(f)

  let rejoined = collect_rejoins(status, 2, [])
  assert list.sort(rejoined, string.compare) == [topic_a, topic_b]

  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

/// A failing connector must not stop the loop — it schedules the next attempt.
pub fn a_failed_attempt_retries_on_the_next_delay_test() {
  let f = fake.start()
  let sock = start_socket(f)
  let status = process.new_subject()
  socket.watch(sock, status)
  let _a = join_ok(f, sock, topic_a, "1")

  fake.fail_next_connects(f, 2)
  fake.enqueue_closed(f)

  let assert Ok(socket.Disconnected(_)) = process.receive(status, 500)
  let assert Ok(socket.Reconnecting(1, _)) = process.receive(status, 500)
  let assert Ok(socket.Reconnecting(2, _)) = process.receive(status, 1000)
  let assert Ok(socket.Reconnecting(3, _)) = process.receive(status, 1000)
  let assert Ok(socket.Connected) = process.receive(status, 1000)

  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

pub fn reconnect_gives_up_at_the_configured_limit_test() {
  let f = fake.start()
  let assert Ok(sock) =
    socket.start(
      socket.test_config(fake.connector_for(f), phoenix.codec())
      |> socket.with_heartbeat_ms(no_heartbeat)
      |> socket.with_backoff(
        fixed_backoff()
        |> backoff.with_initial_ms(10)
        |> backoff.with_max_ms(10)
        |> backoff.with_max_attempts(2),
      ),
    )
  let status = process.new_subject()
  socket.watch(sock, status)
  let a = join_ok(f, sock, topic_a, "1")

  fake.fail_next_connects(f, 10)
  fake.enqueue_closed(f)

  let assert Ok(socket.Disconnected(_)) = process.receive(status, 500)
  let assert Ok(socket.Reconnecting(1, _)) = process.receive(status, 500)
  let assert Ok(socket.Reconnecting(2, _)) = process.receive(status, 500)
  assert process.receive(status, 500) == Ok(socket.GaveUp(2))

  // Giving up is the end of the road, and the channels are told so.
  assert channel.receive(a, 500) == Error(error.ReconnectFailed(2))

  fake.shutdown(f)
}

// -- what happens to traffic in between -------------------------------------

/// Buffering while disconnected would create delivery expectations the library
/// cannot honour, so a correlated push says so instead.
pub fn a_correlated_push_while_disconnected_errors_immediately_test() {
  let f = fake.start()
  let sock = start_socket(f)
  let a = join_ok(f, sock, topic_a, "1")

  fake.fail_next_connects(f, 10)
  fake.enqueue_closed(f)
  process.sleep(30)

  assert channel.push_and_await_reply(a, "say", json.object([]), 500)
    == Error(error.Disconnected)

  fake.shutdown(f)
}

pub fn joining_while_disconnected_errors_immediately_test() {
  let f = fake.start()
  let sock = start_socket(f)
  let _a = join_ok(f, sock, topic_a, "1")

  fake.fail_next_connects(f, 10)
  fake.enqueue_closed(f)
  process.sleep(30)

  assert channel.join(sock, topic_b, json.object([]), 500)
    == Error(error.Disconnected)

  fake.shutdown(f)
}

/// Pending replies belong to the connection that died. Failing them is the
/// only honest answer — they must never be re-correlated against the new one.
pub fn pending_replies_are_failed_at_the_disconnect_test() {
  let f = fake.start()
  let sock = start_socket(f)
  let a = join_ok(f, sock, topic_a, "1")
  let result = process.new_subject()

  process.spawn(fn() {
    process.send(
      result,
      channel.push_and_await_reply(a, "say", json.object([]), 5000),
    )
  })

  process.sleep(30)
  fake.enqueue_closed(f)

  // Fails promptly, well inside its own 5s budget.
  assert process.receive(result, 500) == Ok(Error(error.ChannelClosed))

  fake.shutdown(f)
}

// -- deliberate teardown never reconnects -----------------------------------

pub fn a_deliberate_close_never_reconnects_test() {
  let f = fake.start()
  let sock = start_socket(f)
  let _a = join_ok(f, sock, topic_a, "1")
  let connects_before = fake.connect_count(f)

  let assert Ok(Nil) = socket.close(sock)
  process.sleep(80)

  assert fake.connect_count(f) == connects_before
  fake.shutdown(f)
}

/// Leaving forgets the topic, so a later reconnect does not resurrect it.
pub fn a_left_topic_is_not_rejoined_test() {
  let f = fake.start()
  let sock = start_socket(f)
  let status = process.new_subject()
  socket.watch(sock, status)

  let a = join_ok(f, sock, topic_a, "1")
  let _b = join_ok(f, sock, topic_b, "2")
  let assert Ok(Nil) = channel.leave(a)

  // Only topic B is rejoined; refs 3 was the leave, so B's rejoin is ref 4.
  fake.enqueue_text_after(f, 30, ok_reply(topic_b, "4"))
  fake.enqueue_closed(f)

  let assert Ok(socket.Disconnected(_)) = process.receive(status, 500)
  let assert Ok(socket.Reconnecting(_, _)) = process.receive(status, 500)
  let assert Ok(socket.Connected) = process.receive(status, 1000)
  assert process.receive(status, 1000) == Ok(socket.Rejoined(topic_b))

  // Nothing further — topic A was never rejoined.
  assert process.receive(status, 200) == Error(Nil)

  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

// -- rejoin rejection -------------------------------------------------------

/// A server that refuses a rejoin — expired token, topic gone — ends that
/// channel. Nobody is blocked on a rejoin, so the news reaches the caller two
/// ways: the status stream, and the channel's own events.
pub fn a_refused_rejoin_ends_that_channel_and_is_reported_test() {
  let f = fake.start()
  let sock = start_socket(f)
  let status = process.new_subject()
  socket.watch(sock, status)

  let a = join_ok(f, sock, topic_a, "1")
  let b = join_ok(f, sock, topic_b, "2")

  // A is refused; B is accepted.
  fake.enqueue_text_after(f, 30, error_reply(topic_a, "3"))
  fake.enqueue_text_after(f, 40, ok_reply(topic_b, "4"))
  fake.enqueue_closed(f)

  let assert Ok(socket.Disconnected(_)) = process.receive(status, 500)
  let assert Ok(socket.Reconnecting(_, _)) = process.receive(status, 500)
  let assert Ok(socket.Connected) = process.receive(status, 1000)

  let outcomes = collect_status(status, 2, [])
  assert list.contains(
    outcomes,
    socket.RejoinFailed(topic_a, error.RejoinRejected(topic_a, "error")),
  )
  assert list.contains(outcomes, socket.Rejoined(topic_b))

  // The holder of channel A finds out, rather than waiting forever on a topic
  // the server has forgotten.
  assert channel.receive(a, 500)
    == Error(error.RejoinRejected(topic_a, "error"))

  // Channel B is untouched.
  fake.enqueue_text(f, server_push(topic_b, "b_fine"))
  let assert Ok(incoming) = channel.receive(b, 500)
  assert incoming.event == "b_fine"

  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

// -- refs -------------------------------------------------------------------

/// Continuing rather than resetting means a stale in-flight reply from the old
/// connection can never correlate against a fresh ref on the new one.
pub fn refs_keep_counting_across_a_reconnect_test() {
  let f = fake.start()
  let sock = start_socket(f)
  let status = process.new_subject()
  socket.watch(sock, status)
  let a = join_ok(f, sock, topic_a, "1")

  fake.enqueue_text_after(f, 30, ok_reply(topic_a, "2"))
  fake.enqueue_closed(f)
  let assert Ok(socket.Disconnected(_)) = process.receive(status, 500)
  let assert Ok(socket.Rejoined(_)) = drain_to_rejoin(status)

  channel.push(a, "after", json.object([]))
  process.sleep(30)

  // 1 = join, 2 = rejoin, 3 = this push. Nothing restarted at 1.
  let assert Ok(last) = last_outbound(f)
  let assert Ok(decoded) = phoenix.codec().decode(last)
  assert decoded.ref == Some("3")

  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

// -- helpers ----------------------------------------------------------------

/// A predictable schedule: 100ms doubling to a 1000ms cap, no jitter.
fn fixed_backoff() -> backoff.Backoff {
  backoff.default()
  |> backoff.with_initial_ms(100)
  |> backoff.with_max_ms(1000)
  |> backoff.with_multiplier(200)
  |> backoff.with_jitter(fn(ms) { ms })
}

/// A socket whose reconnect is fast enough to watch in a test.
fn start_socket(f: fake.FakeSocket) -> socket.Socket {
  let assert Ok(sock) =
    socket.start(
      socket.test_config(fake.connector_for(f), phoenix.codec())
      |> socket.with_heartbeat_ms(no_heartbeat)
      |> socket.with_backoff(
        fixed_backoff()
        |> backoff.with_initial_ms(10)
        |> backoff.with_max_ms(20),
      ),
    )
  sock
}

fn join_ok(
  f: fake.FakeSocket,
  sock: socket.Socket,
  topic: String,
  expected_ref: String,
) -> channel.Channel {
  fake.enqueue_text_after(f, 10, ok_reply(topic, expected_ref))
  let assert Ok(ch) = channel.join(sock, topic, json.object([]), 1000)
  ch
}

fn collect_rejoins(
  status: process.Subject(socket.Status),
  remaining: Int,
  acc: List(String),
) -> List(String) {
  case remaining {
    0 -> acc
    _ ->
      case process.receive(status, 1000) {
        Ok(socket.Rejoined(topic)) ->
          collect_rejoins(status, remaining - 1, [topic, ..acc])
        Ok(_) -> collect_rejoins(status, remaining, acc)
        Error(Nil) -> acc
      }
  }
}

fn collect_status(
  status: process.Subject(socket.Status),
  remaining: Int,
  acc: List(socket.Status),
) -> List(socket.Status) {
  case remaining {
    0 -> acc
    _ ->
      case process.receive(status, 1000) {
        Ok(event) -> collect_status(status, remaining - 1, [event, ..acc])
        Error(Nil) -> acc
      }
  }
}

fn drain_to_rejoin(
  status: process.Subject(socket.Status),
) -> Result(socket.Status, Nil) {
  case process.receive(status, 1000) {
    Ok(socket.Rejoined(topic)) -> Ok(socket.Rejoined(topic))
    Ok(_) -> drain_to_rejoin(status)
    Error(Nil) -> Error(Nil)
  }
}

fn ok_reply(topic: String, ref: String) -> String {
  roost_frame.encode_reply(
    join_ref: Some(ref),
    ref: ref,
    topic: topic,
    status: roost_frame.StatusOk,
    response: json.object([]),
  )
}

fn error_reply(topic: String, ref: String) -> String {
  roost_frame.encode_reply(
    join_ref: Some(ref),
    ref: ref,
    topic: topic,
    status: roost_frame.StatusError,
    response: json.object([]),
  )
}

fn server_push(topic: String, event: String) -> String {
  roost_frame.encode(
    join_ref: None,
    ref: None,
    topic: topic,
    event: event,
    payload: json.object([]),
  )
}

fn last_outbound(f: fake.FakeSocket) -> Result(String, Nil) {
  fake.outbound(f) |> list.last
}
