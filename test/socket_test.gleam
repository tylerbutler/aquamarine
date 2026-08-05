//// One socket, many topics.
////
//// These tests cover what the socket/channel split introduced: routing by
//// topic, per-topic termination, leaving without closing, and the guards
//// around joining. Single-topic channel behavior lives in `channel_test`.

import aquamarine/channel
import aquamarine/error
import aquamarine/phoenix
import aquamarine/socket
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import roost/frame as roost_frame
import support/fake_transport as fake

// 24 hours — long enough that no test here sees a heartbeat tick unless it
// asks for one.
const no_heartbeat: Int = 86_400_000

const topic_a: String = "test:a"

const topic_b: String = "test:b"

// -- routing ----------------------------------------------------------------

pub fn two_channels_on_one_socket_each_receive_only_their_own_frames_test() {
  let f = fake.start()
  let sock = start_socket(f, no_heartbeat)
  let a = join_ok(f, sock, topic_a, "1")
  let b = join_ok(f, sock, topic_b, "2")

  fake.enqueue_text(f, server_push(topic_a, "for_a"))
  fake.enqueue_text(f, server_push(topic_b, "for_b"))

  let assert Ok(to_a) = channel.receive(a)
  assert to_a.event == "for_a"
  assert to_a.topic == topic_a

  let assert Ok(to_b) = channel.receive(b)
  assert to_b.event == "for_b"
  assert to_b.topic == topic_b

  // Neither channel saw the other's frame — both mailboxes are now empty.
  assert channel.receive(a) == Error(error.Transport(error.Timeout))
  assert channel.receive(b) == Error(error.Transport(error.Timeout))

  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

/// A frame for a topic nobody joined is dropped, never a crash. The socket has
/// to survive it — subsequent traffic must still route.
pub fn frames_for_an_unknown_topic_do_not_crash_the_socket_test() {
  let f = fake.start()
  let sock = start_socket(f, no_heartbeat)
  let a = join_ok(f, sock, topic_a, "1")

  fake.enqueue_text(f, server_push("test:nobody_joined_this", "ignored"))
  fake.enqueue_text(f, server_push(topic_a, "still_working"))

  let assert Ok(incoming) = channel.receive(a)
  assert incoming.event == "still_working"

  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

/// Behavior change from the fused model: a close/error event used to terminate
/// *the* channel because there was only one. Routed by topic, it terminates
/// only its own.
pub fn a_close_event_on_one_topic_leaves_the_other_channel_alive_test() {
  let f = fake.start()
  let sock = start_socket(f, no_heartbeat)
  let a = join_ok(f, sock, topic_a, "1")
  let b = join_ok(f, sock, topic_b, "2")

  fake.enqueue_text(f, server_push(topic_a, phoenix.codec().close_event))
  assert channel.receive(a) == Error(error.ChannelClosed)

  // The socket and channel B are unaffected.
  fake.enqueue_text(f, server_push(topic_b, "b_survives"))
  let assert Ok(incoming) = channel.receive(b)
  assert incoming.event == "b_survives"

  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

pub fn an_error_event_on_one_topic_leaves_the_other_channel_alive_test() {
  let f = fake.start()
  let sock = start_socket(f, no_heartbeat)
  let a = join_ok(f, sock, topic_a, "1")
  let b = join_ok(f, sock, topic_b, "2")

  fake.enqueue_text(f, server_push(topic_a, phoenix.codec().error_event))
  assert channel.receive(a) == Error(error.ChannelClosed)

  fake.enqueue_text(f, server_push(topic_b, "b_survives"))
  let assert Ok(incoming) = channel.receive(b)
  assert incoming.event == "b_survives"

  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

// -- join guards ------------------------------------------------------------

pub fn joining_an_already_joined_topic_is_an_error_test() {
  let f = fake.start()
  let sock = start_socket(f, no_heartbeat)
  let _a = join_ok(f, sock, topic_a, "1")

  assert channel.join(sock, topic_a, empty(), 200)
    == Error(error.AlreadyJoined(topic_a))

  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

pub fn joining_again_after_leaving_succeeds_test() {
  let f = fake.start()
  let sock = start_socket(f, no_heartbeat)
  let a = join_ok(f, sock, topic_a, "1")

  let assert Ok(Nil) = channel.leave(a)

  // Ref "2" was the leave frame, so the second join goes out under "3".
  let rejoined = join_ok(f, sock, topic_a, "3")
  fake.enqueue_text(f, server_push(topic_a, "after_rejoin"))
  let assert Ok(incoming) = channel.receive(rejoined)
  assert incoming.event == "after_rejoin"

  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

/// The heartbeat topic is the socket's own. Handing it to a channel would
/// route heartbeat replies into application code.
pub fn joining_the_heartbeat_topic_is_rejected_test() {
  let f = fake.start()
  let sock = start_socket(f, no_heartbeat)
  let reserved = phoenix.codec().heartbeat_topic

  assert channel.join(sock, reserved, empty(), 200)
    == Error(error.ReservedTopic(reserved))

  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

// -- leave ------------------------------------------------------------------

pub fn leave_stops_routing_but_leaves_the_socket_usable_test() {
  let f = fake.start()
  let sock = start_socket(f, no_heartbeat)
  let a = join_ok(f, sock, topic_a, "1")
  let b = join_ok(f, sock, topic_b, "2")

  let assert Ok(Nil) = channel.leave(a)

  // A leave frame went out for topic A, carrying the codec's leave event.
  let assert Ok(leave_frame) = last_outbound(f)
  let assert Ok(decoded) = phoenix.codec().decode(leave_frame)
  assert decoded.event == phoenix.codec().leave_event
  assert decoded.topic == topic_a

  // A's frames are dropped now; B is untouched.
  fake.enqueue_text(f, server_push(topic_a, "too_late"))
  fake.enqueue_text(f, server_push(topic_b, "still_here"))
  let assert Ok(incoming) = channel.receive(b)
  assert incoming.event == "still_here"
  assert channel.receive(a) == Error(error.Transport(error.Timeout))

  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

/// Refcount-driven teardown would kill the connection during any transient
/// zero-channel window. The socket stays open until someone closes it.
pub fn the_last_channel_leaving_does_not_close_the_socket_test() {
  let f = fake.start()
  let sock = start_socket(f, no_heartbeat)
  let a = join_ok(f, sock, topic_a, "1")

  let assert Ok(Nil) = channel.leave(a)
  assert !fake.is_closed(f)

  // Still usable: a fresh topic joins fine. Refs 1=join, 2=leave, 3=join.
  let b = join_ok(f, sock, topic_b, "3")
  fake.enqueue_text(f, server_push(topic_b, "socket_alive"))
  let assert Ok(incoming) = channel.receive(b)
  assert incoming.event == "socket_alive"

  let assert Ok(Nil) = socket.close(sock)
  assert fake.is_closed(f)
  fake.shutdown(f)
}

// -- socket ownership -------------------------------------------------------

/// Two clearly-named functions beat one whose meaning depends on where the
/// channel came from.
pub fn close_on_a_connect_owned_channel_closes_the_socket_test() {
  let f = fake.start()
  fake.enqueue_text(f, ok_reply(topic_a, "1"))
  let assert Ok(ch) =
    channel.connect_with(
      fake.connector_for(f),
      topic_a,
      empty(),
      phoenix.codec(),
      no_heartbeat,
    )

  let assert Ok(Nil) = channel.close(ch)
  assert fake.is_closed(f)
  fake.shutdown(f)
}

pub fn leave_on_a_connect_owned_channel_does_not_close_the_socket_test() {
  let f = fake.start()
  fake.enqueue_text(f, ok_reply(topic_a, "1"))
  let assert Ok(ch) =
    channel.connect_with(
      fake.connector_for(f),
      topic_a,
      empty(),
      phoenix.codec(),
      no_heartbeat,
    )

  let assert Ok(Nil) = channel.leave(ch)
  assert !fake.is_closed(f)

  let assert Ok(Nil) = socket.close(channel.socket(ch))
  fake.shutdown(f)
}

pub fn close_on_a_joined_channel_leaves_the_socket_open_test() {
  let f = fake.start()
  let sock = start_socket(f, no_heartbeat)
  let a = join_ok(f, sock, topic_a, "1")

  let assert Ok(Nil) = channel.close(a)
  assert !fake.is_closed(f)

  let assert Ok(Nil) = socket.close(sock)
  assert fake.is_closed(f)
  fake.shutdown(f)
}

// -- heartbeat --------------------------------------------------------------

/// The heartbeat lives on the socket, not the channel: one per connection
/// regardless of how many topics are joined.
pub fn one_heartbeat_per_socket_regardless_of_channel_count_test() {
  let f = fake.start()
  let sock = start_socket(f, 20)
  let _a = join_ok(f, sock, topic_a, "1")
  let _b = join_ok(f, sock, topic_b, "2")

  process.sleep(110)
  let beats = heartbeat_frames(f)

  // Two channels, still one heartbeat's worth of frames over four intervals.
  assert beats >= 3
  assert beats <= 6

  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

pub fn heartbeats_continue_with_zero_channels_joined_test() {
  let f = fake.start()
  let sock = start_socket(f, 20)

  process.sleep(110)
  assert heartbeat_frames(f) >= 3

  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

/// Heartbeat replies arrive on the reserved heartbeat topic, which never has a
/// channel, so they fall out as ordinary unknown-topic drops. No special case
/// is needed, and none exists any more.
pub fn heartbeat_replies_fall_out_as_unknown_topic_drops_test() {
  let f = fake.start()
  let sock = start_socket(f, 20)
  let a = join_ok(f, sock, topic_a, "1")

  process.sleep(50)
  fake.enqueue_text(
    f,
    roost_frame.encode_reply(
      join_ref: None,
      ref: "2",
      topic: roost_frame.heartbeat_topic,
      status: roost_frame.StatusOk,
      response: empty(),
    ),
  )
  fake.enqueue_text(f, server_push(topic_a, "real"))

  let assert Ok(incoming) = channel.receive(a)
  assert incoming.event == "real"

  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

// -- socket teardown --------------------------------------------------------

pub fn closing_the_socket_terminates_every_channel_test() {
  let f = fake.start()
  let sock = start_socket(f, no_heartbeat)
  let a = join_ok(f, sock, topic_a, "1")
  let b = join_ok(f, sock, topic_b, "2")

  let assert Ok(Nil) = socket.close(sock)

  assert channel.receive(a) == Error(error.ChannelClosed)
  assert channel.receive(b) == Error(error.ChannelClosed)

  fake.shutdown(f)
}

pub fn losing_the_socket_terminates_every_channel_test() {
  let f = fake.start()
  let sock = start_socket(f, no_heartbeat)
  let a = join_ok(f, sock, topic_a, "1")
  let b = join_ok(f, sock, topic_b, "2")

  fake.enqueue_closed(f)

  assert channel.receive(a) == Error(error.ChannelClosed)
  assert channel.receive(b) == Error(error.ChannelClosed)

  fake.shutdown(f)
}

// -- helpers ----------------------------------------------------------------

fn empty() -> json.Json {
  json.object([])
}

fn start_socket(f: fake.FakeSocket, heartbeat_ms: Int) -> socket.Socket {
  let assert Ok(sock) =
    socket.start(fake.connector_for(f), phoenix.codec(), heartbeat_ms)
  sock
}

/// Join `topic`, scripting the server to accept it on `expected_ref`.
///
/// The reply is delivered from another process because the fake releases
/// frames immediately once the channel has spoken — an eagerly enqueued reply
/// would arrive before the join it is answering.
fn join_ok(
  f: fake.FakeSocket,
  sock: socket.Socket,
  topic: String,
  expected_ref: String,
) -> channel.Channel {
  fake.enqueue_text_after(f, 10, ok_reply(topic, expected_ref))
  let assert Ok(ch) = channel.join(sock, topic, empty(), 1000)
  ch
}

fn ok_reply(topic: String, ref: String) -> String {
  roost_frame.encode_reply(
    join_ref: Some(ref),
    ref: ref,
    topic: topic,
    status: roost_frame.StatusOk,
    response: empty(),
  )
}

fn server_push(topic: String, event: String) -> String {
  roost_frame.encode(
    join_ref: None,
    ref: None,
    topic: topic,
    event: event,
    payload: empty(),
  )
}

fn last_outbound(f: fake.FakeSocket) -> Result(String, Nil) {
  fake.outbound(f) |> list.last
}

fn heartbeat_frames(f: fake.FakeSocket) -> Int {
  fake.outbound(f)
  |> list.filter(fn(frame) {
    case phoenix.codec().decode(frame) {
      Ok(decoded) -> decoded.event == "heartbeat"
      Error(_) -> False
    }
  })
  |> list.length
}
