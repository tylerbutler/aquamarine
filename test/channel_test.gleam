//// Callback/runtime coverage for `aquamarine/channel`.
////
//// These tests exercise join rejection, decode failure, heartbeat, and
//// handler callback paths against a real Beryl server.

import aquamarine/channel
import aquamarine/codec.{type Incoming}
import aquamarine/error
import aquamarine/phoenix
import aquamarine/ref
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{Some}
import gleeunit/should
import roost/frame as roost_frame
import support/channel_server

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

type SelfCallEvent {
  NeedChannel(process.Subject(channel.Channel(SelfCallState)))
  SelfCloseResult(Result(Nil, error.AquamarineError))
  SelfPushResult(Result(Nil, error.AquamarineError))
}

type SelfCallState {
  SelfCallState(events: process.Subject(SelfCallEvent))
}

type BlockingEvent {
  BlockingStarted
}

type BlockingState {
  BlockingState(events: process.Subject(BlockingEvent), blocked: Bool)
}

// -- Helpers ----------------------------------------------------------------

fn empty_payload() -> json.Json {
  json.object([])
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

fn slow_push_codec() -> codec.Codec {
  let phoenix_codec = phoenix.codec()
  codec.Codec(
    decode: phoenix_codec.decode,
    encode_join: phoenix_codec.encode_join,
    encode_push: fn(join_ref, push_ref, topic, event, payload) {
      process.sleep(5500)
      phoenix_codec.encode_push(join_ref, push_ref, topic, event, payload)
    },
    encode_heartbeat: phoenix_codec.encode_heartbeat,
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

pub fn connect_failure_cleanup_does_not_leave_orphan_replies_test() {
  process.flush_messages()
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

  process.sleep(20)
  process.new_selector()
  |> process.select_other(fn(_) { True })
  |> process.selector_receive(20)
  |> should.equal(Error(Nil))

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

pub fn connect_does_not_time_out_on_slow_on_joined_test() {
  let events = process.new_subject()
  let server = channel_server.start()
  let port = channel_server.port(server)
  channel_server.register_ok(
    server,
    test_topic,
    json.object([#("welcome", json.string("ok"))]),
  )

  let result =
    channel.connect(
      channel.config(
        host: "127.0.0.1",
        port: port,
        path: "/socket/websocket",
        topic: test_topic,
        payload: json.object([]),
        codec: phoenix.codec(),
      ),
      slow_joined_handlers(),
      CallbackState(events),
    )

  let assert Ok(ch) = result
  process.receive(events, 7000)
  |> should.equal(Ok(Joined("ok")))

  let assert Ok(Nil) = channel.close(ch)
  channel_server.stop(server)
}

pub fn runtime_monitor_suppresses_startup_exit_callbacks_test() {
  let events = process.new_subject()
  let assert Ok(counter) = ref.start()
  let pid = process.spawn_unlinked(process.sleep_forever)
  let assert Ok(_) =
    channel.start_runtime_monitor(
      pid,
      runtime_handlers(events),
      RuntimeState(events: events, joined: False),
      counter,
    )

  process.send_abnormal_exit(pid, "startup failed")

  process.receive(events, 100)
  |> should.equal(Error(Nil))
}

pub fn callback_initiated_close_fails_fast_test() {
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
      self_close_handlers(),
      SelfCallState(events:),
    )

  channel_server.broadcast(
    server,
    test_topic,
    "close_from_callback",
    empty_payload(),
  )
  let assert Ok(NeedChannel(channel_ref)) = process.receive(events, 1000)
  process.send(channel_ref, ch)

  process.receive(events, 6000)
  |> should.equal(
    Ok(
      SelfCloseResult(
        Error(error.InternalError(
          "channel operations cannot be called from channel callbacks",
        )),
      ),
    ),
  )

  let assert Ok(Nil) = channel.close(ch)
  channel_server.stop(server)
}

pub fn callback_initiated_push_fails_fast_test() {
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
      self_push_handlers(),
      SelfCallState(events:),
    )

  channel_server.broadcast(
    server,
    test_topic,
    "push_from_callback",
    empty_payload(),
  )
  let assert Ok(NeedChannel(channel_ref)) = process.receive(events, 1000)
  process.send(channel_ref, ch)

  process.receive(events, 6000)
  |> should.equal(
    Ok(
      SelfPushResult(
        Error(error.InternalError(
          "channel operations cannot be called from channel callbacks",
        )),
      ),
    ),
  )

  let assert Ok(Nil) = channel.close(ch)
  channel_server.stop(server)
}

pub fn timed_out_push_does_not_send_later_test() {
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
        payload: json.object([]),
        codec: phoenix.codec(),
      ),
      blocking_handlers(),
      BlockingState(events:, blocked: False),
    )

  channel_server.broadcast(server, test_topic, "block", empty_payload())
  process.receive(events, 1000)
  |> should.equal(Ok(BlockingStarted))

  channel.push(ch, "late", json.object([#("body", json.string("hello"))]))
  |> should.equal(Error(error.ReplyTimeout))

  process.receive(seen, 1000)
  |> should.equal(Error(Nil))

  let assert Ok(Nil) = channel.close(ch)
  channel_server.stop(server)
}

pub fn timed_out_close_does_not_close_later_test() {
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
        payload: json.object([]),
        codec: phoenix.codec(),
      ),
      blocking_handlers(),
      BlockingState(events:, blocked: False),
    )

  channel_server.broadcast(server, test_topic, "block", empty_payload())
  process.receive(events, 1000)
  |> should.equal(Ok(BlockingStarted))

  channel.close(ch)
  |> should.equal(Error(error.ReplyTimeout))

  process.sleep(1500)
  channel.push(ch, "still_open", json.object([#("body", json.string("hello"))]))
  |> should.equal(Ok(Nil))
  process.receive(seen, 1000)
  |> should.equal(Ok("still_open"))

  let assert Ok(Nil) = channel.close(ch)
  channel_server.stop(server)
}

pub fn claimed_push_waits_for_real_result_test() {
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
        payload: json.object([]),
        codec: slow_push_codec(),
      ),
      callback_handlers(),
      CallbackState(events),
    )

  process.receive(events, 1000)
  |> should.equal(Ok(Joined("ok")))

  channel.push(ch, "claimed", json.object([#("body", json.string("hello"))]))
  |> should.equal(Ok(Nil))
  process.receive(seen, 1000)
  |> should.equal(Ok("claimed"))

  let assert Ok(Nil) = channel.close(ch)
  channel_server.stop(server)
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

  channel.close(ch) |> should.equal(Error(error.ChannelClosed))
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

  channel.close(ch) |> should.equal(Error(error.ChannelClosed))
  channel_server.stop(server)
}

pub fn runtime_transport_failure_calls_on_error_test() {
  let events = process.new_subject()
  let server = channel_server.start()
  let port = channel_server.port(server)
  channel_server.register_ok(
    server,
    test_topic,
    json.object([#("welcome", json.string("ok"))]),
  )

  let assert Ok(_ch) =
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

  channel_server.crash(server)

  case process.receive(events, 1000) {
    Ok(RuntimeErrorSeen(error.Transport(error.SocketReceiveFailed(_)))) -> Nil
    other ->
      other
      |> should.equal(
        Ok(RuntimeErrorSeen(error.Transport(error.SocketReceiveFailed("")))),
      )
  }
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

  process.receive(seen, 5000)
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

  channel.push(ch, "after_close", empty_payload())
  |> should.equal(Error(error.ChannelClosed))

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

fn slow_joined_handlers() -> channel.Handlers(CallbackState) {
  channel.handlers(
    on_joined: fn(state: CallbackState, payload) {
      process.sleep(5500)
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

fn self_close_handlers() -> channel.Handlers(SelfCallState) {
  channel.handlers(
    on_joined: fn(state: SelfCallState, _payload) { channel.continue(state) },
    on_message: fn(state: SelfCallState, _incoming: Incoming) {
      let channel_ref = process.new_subject()
      process.send(state.events, NeedChannel(channel_ref))
      let assert Ok(ch) = process.receive(channel_ref, 1000)
      process.send(state.events, SelfCloseResult(channel.close(ch)))
      channel.continue(state)
    },
    on_error: fn(state: SelfCallState, _err) { channel.continue(state) },
    on_closed: fn(state: SelfCallState) { channel.continue(state) },
  )
}

fn self_push_handlers() -> channel.Handlers(SelfCallState) {
  channel.handlers(
    on_joined: fn(state: SelfCallState, _payload) { channel.continue(state) },
    on_message: fn(state: SelfCallState, _incoming: Incoming) {
      let channel_ref = process.new_subject()
      process.send(state.events, NeedChannel(channel_ref))
      let assert Ok(ch) = process.receive(channel_ref, 1000)
      process.send(
        state.events,
        SelfPushResult(channel.push(ch, "from_callback", empty_payload())),
      )
      channel.continue(state)
    },
    on_error: fn(state: SelfCallState, _err) { channel.continue(state) },
    on_closed: fn(state: SelfCallState) { channel.continue(state) },
  )
}

fn blocking_handlers() -> channel.Handlers(BlockingState) {
  channel.handlers(
    on_joined: fn(state: BlockingState, _payload) { channel.continue(state) },
    on_message: fn(state: BlockingState, _incoming: Incoming) {
      case state.blocked {
        False -> {
          process.send(state.events, BlockingStarted)
          process.sleep(5500)
          channel.continue(BlockingState(..state, blocked: True))
        }
        True -> channel.continue(state)
      }
    },
    on_error: fn(state: BlockingState, _err) { channel.continue(state) },
    on_closed: fn(state: BlockingState) { channel.continue(state) },
  )
}
