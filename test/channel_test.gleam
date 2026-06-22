//// Branch-coverage tests for `aquamarine/channel` using an in-memory
//// transport.
////
//// These tests exercise paths that the integration test cannot reach
//// without standing up a misbehaving server: join rejections, malformed
//// replies, decode failures, transport errors, and the various inbound
//// frame classes that `receive` must skip or terminate on.

import aquamarine/channel
import aquamarine/codec.{type Incoming}
import aquamarine/error
import aquamarine/phoenix
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import gleeunit/should
import roost/frame as roost_frame
import support/channel_server
import support/fake_transport as fake

// 24 hours — long enough that no test in this file ever sees a heartbeat tick.
const no_heartbeat: Int = 86_400_000

const test_topic: String = "test:lobby"

type TestEvent {
  Joined(String)
  Message(Incoming)
  ErrorSeen(error.AquamarineError)
  Closed
}

type CallbackState {
  CallbackState(events: process.Subject(TestEvent))
}

type RuntimeEvent {
  RuntimeJoined
  RuntimeMessage(Bool, String)
  RuntimeErrorSeen(error.AquamarineError)
  RuntimeClosed
}

type RuntimeState {
  RuntimeState(events: process.Subject(RuntimeEvent), joined: Bool)
}

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
fn connect_with_fake(fake_socket: fake.FakeSocket) {
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

fn runtime_handlers(
  _events: process.Subject(RuntimeEvent),
) -> channel.Handlers(RuntimeState) {
  channel.handlers(
    on_joined: fn(state: RuntimeState, _payload) {
      process.send(state.events, RuntimeJoined)
      channel.continue(RuntimeState(..state, joined: True))
    },
    on_message: fn(state: RuntimeState, incoming: Incoming) {
      process.send(state.events, RuntimeMessage(state.joined, incoming.event))
      channel.continue(state)
    },
    on_error: fn(state: RuntimeState, err) {
      process.send(state.events, RuntimeErrorSeen(err))
      channel.continue(state)
    },
    on_closed: fn(state: RuntimeState) {
      process.send(state.events, RuntimeClosed)
      channel.continue(state)
    },
  )
}

fn decode_fails_on_boom_codec() -> codec.Codec {
  let phoenix_codec = phoenix.codec()
  codec.Codec(
    decode: fn(text) {
      case phoenix_codec.decode(text) {
        Ok(incoming) if incoming.event == "boom" ->
          Error(codec.InvalidFormat("boom"))
        other -> other
      }
    },
    encode_join: phoenix_codec.encode_join,
    encode_push: phoenix_codec.encode_push,
    encode_heartbeat: phoenix_codec.encode_heartbeat,
    join_event: phoenix_codec.join_event,
    reply_event: phoenix_codec.reply_event,
    close_event: phoenix_codec.close_event,
    error_event: phoenix_codec.error_event,
    heartbeat_topic: phoenix_codec.heartbeat_topic,
  )
}

fn heartbeat_on_join_topic_codec() -> codec.Codec {
  let phoenix_codec = phoenix.codec()
  codec.Codec(
    decode: phoenix_codec.decode,
    encode_join: phoenix_codec.encode_join,
    encode_push: phoenix_codec.encode_push,
    encode_heartbeat: fn(ref) {
      roost_frame.encode(
        join_ref: Some(ref),
        ref: Some(ref),
        topic: test_topic,
        // Beryl reserves the literal `heartbeat` event, so use a normal
        // channel event name here to verify the timer actually fires.
        event: "tick",
        payload: empty_payload(),
      )
    },
    join_event: phoenix_codec.join_event,
    reply_event: phoenix_codec.reply_event,
    close_event: phoenix_codec.close_event,
    error_event: phoenix_codec.error_event,
    heartbeat_topic: phoenix_codec.heartbeat_topic,
  )
}

// -- Tests ------------------------------------------------------------------

pub fn connect_waits_for_join_and_calls_on_joined_test() {
  let events = process.new_subject()
  let server = channel_server.start()
  let port = channel_server.port(server)
  channel_server.register_ok(
    server,
    test_topic,
    json.object([#("welcome", json.string("ok"))]),
  )

  let assert Ok(ch) =
    channel.connect(
      channel.config(
        host: "127.0.0.1",
        port: port,
        path: "/socket/websocket",
        topic: test_topic,
        payload: json.object([]),
        codec: phoenix.codec(),
      ),
      callback_handlers(),
      CallbackState(events),
    )

  process.receive(events, 1000)
  |> should.equal(Ok(Joined("ok")))

  let assert Ok(Nil) = channel.close(ch)
  channel_server.stop(server)
}

pub fn connect_surfaces_join_rejection_test() {
  let server = channel_server.start()
  let port = channel_server.port(server)
  channel_server.register_rejected(server, test_topic)

  channel.connect(
    channel.config(
      host: "127.0.0.1",
      port: port,
      path: "/socket/websocket",
      topic: test_topic,
      payload: json.object([]),
      codec: phoenix.codec(),
    ),
    callback_handlers(),
    CallbackState(process.new_subject()),
  )
  |> should.equal(Error(error.JoinRejected("error")))

  channel_server.stop(server)
}

pub fn connect_returns_channel_closed_when_on_joined_stops_test() {
  let events = process.new_subject()
  let server = channel_server.start()
  let port = channel_server.port(server)
  channel_server.register_ok(
    server,
    test_topic,
    json.object([#("welcome", json.string("stop"))]),
  )

  channel.connect(
    channel.config(
      host: "127.0.0.1",
      port: port,
      path: "/socket/websocket",
      topic: test_topic,
      payload: json.object([]),
      codec: phoenix.codec(),
    ),
    stopping_handlers(),
    CallbackState(events),
  )
  |> should.equal(Error(error.ChannelClosed))

  process.receive(events, 1000)
  |> should.equal(Ok(Joined("stop")))

  channel_server.stop(server)
}

pub fn channel_tests_test() {
  // channel.connect_with: returns Ok on a matching ok join reply
  let f = fake.start()
  let ch = connect_with_fake(f)

  // The very first outbound frame must be the join.
  let assert [join_frame, ..] = fake.outbound(f)
  let assert Ok(decoded) = phoenix.codec().decode(join_frame)
  decoded.event |> should.equal(roost_frame.join_event)
  decoded.topic |> should.equal(test_topic)

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)

  // maps a non-ok status to JoinRejected
  let f = fake.start()
  fake.enqueue_text(f, error_join_reply("1"))

  channel.connect_with(
    fake.connector_for(f),
    test_topic,
    empty_payload(),
    phoenix.codec(),
    no_heartbeat,
  )
  |> should.equal(Error(error.JoinRejected("error")))

  // Cleanup must close the underlying transport.
  fake.is_closed(f) |> should.equal(True)
  fake.shutdown(f)

  // maps a malformed reply payload to JoinRejected("malformed reply")
  let f = fake.start()
  fake.enqueue_text(f, malformed_reply("1"))

  channel.connect_with(
    fake.connector_for(f),
    test_topic,
    empty_payload(),
    phoenix.codec(),
    no_heartbeat,
  )
  |> should.equal(Error(error.JoinRejected("malformed reply")))

  fake.is_closed(f) |> should.equal(True)
  fake.shutdown(f)

  // maps undecodable text on the reply channel to DecodeFailed
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
      |> should.equal(
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

  fake.is_closed(f) |> should.equal(True)
  fake.shutdown(f)

  // maps a Closed frame during handshake to ChannelClosed
  let f = fake.start()
  fake.enqueue_closed(f)

  channel.connect_with(
    fake.connector_for(f),
    test_topic,
    empty_payload(),
    phoenix.codec(),
    no_heartbeat,
  )
  |> should.equal(Error(error.ChannelClosed))

  fake.is_closed(f) |> should.equal(True)
  fake.shutdown(f)

  // propagates a send-side error on the join frame and cleans up
  let f = fake.start()
  fake.enqueue_send_error(f, error.Transport(error.SocketSendFailed("timeout")))

  channel.connect_with(
    fake.connector_for(f),
    test_topic,
    empty_payload(),
    phoenix.codec(),
    no_heartbeat,
  )
  |> should.equal(Error(error.Transport(error.SocketSendFailed("timeout"))))

  fake.is_closed(f) |> should.equal(True)
  fake.shutdown(f)

  // skips non-matching frames before the join reply
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

  // propagates a connector failure verbatim
  let connector =
    fake.failing_connector(
      error.Transport(error.SocketConnectionFailed("nope")),
    )
  channel.connect_with(
    connector,
    test_topic,
    empty_payload(),
    phoenix.codec(),
    no_heartbeat,
  )
  |> should.equal(Error(error.Transport(error.SocketConnectionFailed("nope"))))

  // channel.push: encodes the topic, event, payload, and a fresh ref
  let f = fake.start()
  let ch = connect_with_fake(f)

  let assert Ok(Nil) =
    channel.push(ch, "say", json.object([#("body", json.string("hi"))]))

  // outbound: [join, push]
  let assert [_, push_frame] = fake.outbound(f)
  let assert Ok(decoded) = phoenix.codec().decode(push_frame)
  decoded.topic |> should.equal(test_topic)
  decoded.event |> should.equal("say")
  decoded.join_ref |> should.equal(Some("1"))
  // Join consumed ref 1; the next allocation is "2".
  decoded.ref |> should.equal(Some("2"))

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)

  // channel.push: maps a transport send failure to the underlying error
  let f = fake.start()
  let ch = connect_with_fake(f)

  fake.enqueue_send_error(
    f,
    error.Transport(error.SocketConnectionFailed("gone")),
  )

  channel.push(ch, "say", empty_payload())
  |> should.equal(Error(error.Transport(error.SocketConnectionFailed("gone"))))

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)

  // channel.push: reaches the server and delivers its reply to callbacks
  let events = process.new_subject()
  let seen = process.new_subject()
  let server = channel_server.start()
  let port = channel_server.port(server)
  channel_server.register_echo(server, test_topic, seen)

  let assert Ok(ch) =
    channel.connect(
      channel.config(
        host: "127.0.0.1",
        port: port,
        path: "/socket/websocket",
        topic: test_topic,
        payload: empty_payload(),
        codec: phoenix.codec(),
      ),
      callback_handlers(),
      CallbackState(events),
    )

  process.receive(events, 1000)
  |> should.equal(Ok(Joined("ok")))

  let assert Ok(Nil) =
    channel.push(ch, "say", json.object([#("body", json.string("hi"))]))

  process.receive(seen, 1000)
  |> should.equal(Ok("say"))

  let received = process.receive(events, 1000)
  case received {
    Ok(Message(incoming)) -> {
      incoming.event |> should.equal(phoenix.codec().reply_event)
      incoming.topic |> should.equal(test_topic)
      incoming.ref |> should.equal(Some("2"))
    }
    _ -> panic as "expected callback reply message"
  }

  let assert Ok(Nil) = channel.close(ch)
  let _ = channel_server.stop(server)

  // channel.receive: returns the next application frame
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
  incoming.event |> should.equal("tick")
  incoming.topic |> should.equal(test_topic)
  decode_n(incoming.payload) |> should.equal(Ok(7))

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)

  // channel.receive: skips a binary frame and returns the next text frame
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
  incoming.event |> should.equal("after_binary")

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)

  // channel.receive: skips a heartbeat reply and returns the next channel frame
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
  incoming.event |> should.equal("after_hb")

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)

  // channel.receive: returns ChannelClosed on a phx_close event
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

  channel.receive(ch) |> should.equal(Error(error.ChannelClosed))

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)

  // channel.receive: returns ChannelClosed on a phx_error event
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

  channel.receive(ch) |> should.equal(Error(error.ChannelClosed))

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)

  // channel.receive: returns ChannelClosed on a Closed frame
  let f = fake.start()
  let ch = connect_with_fake(f)

  fake.enqueue_closed(f)

  channel.receive(ch) |> should.equal(Error(error.ChannelClosed))

  let assert Ok(Nil) = channel.close(ch)
  fake.shutdown(f)

  // channel.receive: returns ChannelClosed for callback channels
  let events = process.new_subject()
  let server = channel_server.start()
  let port = channel_server.port(server)
  channel_server.register_ok(
    server,
    test_topic,
    json.object([#("welcome", json.string("ok"))]),
  )

  let assert Ok(ch) =
    channel.connect(
      channel.config(
        host: "127.0.0.1",
        port: port,
        path: "/socket/websocket",
        topic: test_topic,
        payload: json.object([]),
        codec: phoenix.codec(),
      ),
      callback_handlers(),
      CallbackState(events),
    )

  channel.receive(ch) |> should.equal(Error(error.ChannelClosed))

  let assert Ok(Nil) = channel.close(ch)
  let _ = channel_server.stop(server)

  // channel.receive: returns DecodeFailed on a malformed text frame
  let f = fake.start()
  let ch = connect_with_fake(f)

  fake.enqueue_text(f, "not json")

  case channel.receive(ch) {
    Error(error.DecodeFailed(_)) -> Nil
    other ->
      other
      |> should.equal(
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

  // channel.close: closes the transport and stops the heartbeat actor
  let f = fake.start()
  let ch = connect_with_fake(f)

  let assert Ok(Nil) = channel.close(ch)

  fake.is_closed(f) |> should.equal(True)
  fake.shutdown(f)

  // channel.close: propagates a transport close error
  let f = fake.start()
  let ch = connect_with_fake(f)

  fake.enqueue_close_error(
    f,
    error.Transport(error.SocketConnectionFailed("close failed")),
  )

  channel.close(ch)
  |> should.equal(
    Error(error.Transport(error.SocketConnectionFailed("close failed"))),
  )

  // Give the heartbeat/counter actors a tick to fully exit before the
  // fake socket is shut down.
  process.sleep(5)
  fake.shutdown(f)
}

pub fn runtime_application_messages_use_updated_join_state_test() {
  let events = process.new_subject()
  let server = channel_server.start()
  let port = channel_server.port(server)
  channel_server.register_ok(
    server,
    test_topic,
    json.object([#("welcome", json.string("ok"))]),
  )

  let assert Ok(ch) =
    channel.connect(
      channel.config(
        host: "127.0.0.1",
        port: port,
        path: "/socket/websocket",
        topic: test_topic,
        payload: empty_payload(),
        codec: phoenix.codec(),
      ),
      runtime_handlers(events),
      RuntimeState(events, False),
    )

  let assert Ok(RuntimeJoined) = process.receive(events, 1000)

  channel_server.broadcast(
    server,
    test_topic,
    "tick",
    json.object([#("n", json.int(7))]),
  )

  process.receive(events, 1000)
  |> should.equal(Ok(RuntimeMessage(True, "tick")))

  let assert Ok(Nil) = channel.close(ch)
  channel_server.stop(server)
}

pub fn runtime_close_event_calls_on_closed_test() {
  let events = process.new_subject()
  let server = channel_server.start()
  let port = channel_server.port(server)
  channel_server.register_ok(
    server,
    test_topic,
    json.object([#("welcome", json.string("ok"))]),
  )

  let assert Ok(ch) =
    channel.connect(
      channel.config(
        host: "127.0.0.1",
        port: port,
        path: "/socket/websocket",
        topic: test_topic,
        payload: empty_payload(),
        codec: phoenix.codec(),
      ),
      runtime_handlers(events),
      RuntimeState(events, False),
    )

  let assert Ok(RuntimeJoined) = process.receive(events, 1000)

  channel_server.broadcast(
    server,
    test_topic,
    phoenix.codec().close_event,
    empty_payload(),
  )

  process.receive(events, 1000) |> should.equal(Ok(RuntimeClosed))

  let assert Ok(Nil) = channel.close(ch)
  channel_server.stop(server)
}

pub fn runtime_error_event_calls_on_error_test() {
  let events = process.new_subject()
  let server = channel_server.start()
  let port = channel_server.port(server)
  channel_server.register_ok(
    server,
    test_topic,
    json.object([#("welcome", json.string("ok"))]),
  )

  let assert Ok(ch) =
    channel.connect(
      channel.config(
        host: "127.0.0.1",
        port: port,
        path: "/socket/websocket",
        topic: test_topic,
        payload: empty_payload(),
        codec: phoenix.codec(),
      ),
      runtime_handlers(events),
      RuntimeState(events, False),
    )

  let assert Ok(RuntimeJoined) = process.receive(events, 1000)

  channel_server.broadcast(
    server,
    test_topic,
    phoenix.codec().error_event,
    empty_payload(),
  )

  process.receive(events, 1000)
  |> should.equal(Ok(RuntimeErrorSeen(error.ChannelClosed)))

  let assert Ok(Nil) = channel.close(ch)
  channel_server.stop(server)
}

pub fn runtime_decode_failures_call_on_error_test() {
  let events = process.new_subject()
  let server = channel_server.start()
  let port = channel_server.port(server)
  channel_server.register_ok(server, test_topic, empty_payload())

  let assert Ok(ch) =
    channel.connect(
      channel.config(
        host: "127.0.0.1",
        port: port,
        path: "/socket/websocket",
        topic: test_topic,
        payload: empty_payload(),
        codec: decode_fails_on_boom_codec(),
      ),
      runtime_handlers(events),
      RuntimeState(events, False),
    )

  let assert Ok(RuntimeJoined) = process.receive(events, 1000)

  channel_server.broadcast(server, test_topic, "boom", empty_payload())

  process.receive(events, 1000)
  |> should.equal(
    Ok(RuntimeErrorSeen(error.DecodeFailed(codec.InvalidFormat("boom")))),
  )

  let assert Ok(Nil) = channel.close(ch)
  channel_server.stop(server)
}

pub fn runtime_heartbeat_replies_are_swallowed_test() {
  let events = process.new_subject()
  let server = channel_server.start()
  let port = channel_server.port(server)
  let heartbeat_topic = phoenix.codec().heartbeat_topic
  channel_server.register_ok(server, heartbeat_topic, empty_payload())

  let assert Ok(ch) =
    channel.connect(
      channel.config(
        host: "127.0.0.1",
        port: port,
        path: "/socket/websocket",
        topic: heartbeat_topic,
        payload: empty_payload(),
        codec: phoenix.codec(),
      ),
      runtime_handlers(events),
      RuntimeState(events, False),
    )

  let assert Ok(RuntimeJoined) = process.receive(events, 1000)

  channel_server.broadcast(
    server,
    heartbeat_topic,
    phoenix.codec().reply_event,
    empty_payload(),
  )
  channel_server.broadcast(server, heartbeat_topic, "after_hb", empty_payload())

  process.receive(events, 1000)
  |> should.equal(Ok(RuntimeMessage(True, "after_hb")))

  let assert Ok(Nil) = channel.close(ch)
  channel_server.stop(server)
}

pub fn runtime_heartbeat_schedules_after_join_test() {
  let events = process.new_subject()
  let seen = process.new_subject()
  let server = channel_server.start()
  let port = channel_server.port(server)
  channel_server.register_echo(server, test_topic, seen)

  let assert Ok(ch) =
    channel.connect_with_heartbeat(
      channel.config(
        host: "127.0.0.1",
        port: port,
        path: "/socket/websocket",
        topic: test_topic,
        payload: empty_payload(),
        codec: heartbeat_on_join_topic_codec(),
      ),
      callback_handlers(),
      CallbackState(events),
      20,
    )

  process.receive(events, 1000)
  |> should.equal(Ok(Joined("ok")))

  process.receive(seen, 1000)
  |> should.equal(Ok("tick"))

  let assert Ok(Message(incoming)) = process.receive(events, 1000)
  incoming.event |> should.equal(phoenix.codec().reply_event)
  incoming.topic |> should.equal(test_topic)
  incoming.ref |> should.equal(Some("2"))

  let assert Ok(Nil) = channel.close(ch)
  channel_server.stop(server)
}

pub fn close_stops_actor_and_later_push_does_not_hang_test() {
  let events = process.new_subject()
  let server = channel_server.start()
  let port = channel_server.port(server)
  channel_server.register_ok(
    server,
    test_topic,
    json.object([#("welcome", json.string("ok"))]),
  )

  let assert Ok(ch) =
    channel.connect(
      channel.config(
        host: "127.0.0.1",
        port: port,
        path: "/socket/websocket",
        topic: test_topic,
        payload: empty_payload(),
        codec: phoenix.codec(),
      ),
      callback_handlers(),
      CallbackState(events),
    )

  let assert Ok(Joined("ok")) = process.receive(events, 1000)
  let assert Ok(Nil) = channel.close(ch)

  case channel.push(ch, "after_close", empty_payload()) {
    Error(error.ChannelClosed) -> Nil
    Error(error.ReplyTimeout) -> Nil
    other -> other |> should.equal(Error(error.ChannelClosed))
  }

  channel_server.stop(server)
}

pub fn close_does_not_call_on_closed_for_self_close_test() {
  let events = process.new_subject()
  let server = channel_server.start()
  let port = channel_server.port(server)
  channel_server.register_ok(
    server,
    test_topic,
    json.object([#("welcome", json.string("ok"))]),
  )

  let assert Ok(ch) =
    channel.connect(
      channel.config(
        host: "127.0.0.1",
        port: port,
        path: "/socket/websocket",
        topic: test_topic,
        payload: empty_payload(),
        codec: phoenix.codec(),
      ),
      callback_handlers(),
      CallbackState(events),
    )

  let assert Ok(Joined("ok")) = process.receive(events, 1000)
  let assert Ok(Nil) = channel.close(ch)

  process.receive(events, 20)
  |> should.equal(Error(Nil))

  channel_server.stop(server)
}

fn decode_n(payload) -> Result(Int, Nil) {
  let decoder = {
    use n <- decode.field("n", decode.int)
    decode.success(n)
  }
  decode.run(payload, decoder)
  |> result.map_error(fn(_) { Nil })
}

fn callback_handlers() -> channel.Handlers(CallbackState) {
  channel.handlers(
    on_joined: fn(state: CallbackState, payload) {
      let decoder = {
        use welcome <- decode.field("welcome", decode.string)
        decode.success(welcome)
      }
      let assert Ok(value) = decode.run(payload, decoder)
      process.send(state.events, Joined(value))
      channel.continue(state)
    },
    on_message: fn(state: CallbackState, incoming: Incoming) {
      process.send(state.events, Message(incoming))
      channel.continue(state)
    },
    on_error: fn(state: CallbackState, err) {
      process.send(state.events, ErrorSeen(err))
      channel.continue(state)
    },
    on_closed: fn(state: CallbackState) {
      process.send(state.events, Closed)
      channel.continue(state)
    },
  )
}

fn stopping_handlers() -> channel.Handlers(CallbackState) {
  channel.handlers(
    on_joined: fn(state: CallbackState, payload) {
      let decoder = {
        use welcome <- decode.field("welcome", decode.string)
        decode.success(welcome)
      }
      let assert Ok(value) = decode.run(payload, decoder)
      process.send(state.events, Joined(value))
      channel.stop()
    },
    on_message: fn(state: CallbackState, incoming: Incoming) {
      process.send(state.events, Message(incoming))
      channel.continue(state)
    },
    on_error: fn(state: CallbackState, err) {
      process.send(state.events, ErrorSeen(err))
      channel.continue(state)
    },
    on_closed: fn(state: CallbackState) {
      process.send(state.events, Closed)
      channel.continue(state)
    },
  )
}
