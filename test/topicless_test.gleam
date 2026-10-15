import aquamarine/backoff
import aquamarine/channel
import aquamarine/codec
import aquamarine/error
import aquamarine/phoenix
import aquamarine/socket
import aquamarine/transport
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import roost/frame
import support/fake_transport as fake

const topic = "document:t1:d1"

pub fn routes_topicless_events_but_not_heartbeats_or_other_topics_test() -> Nil {
  let transport = fake.start()
  let socket = start_socket(transport, topicless_codec())
  let channel = join(transport, socket, "1")

  fake.enqueue_text(
    transport,
    push(phoenix.codec().heartbeat_topic, "heartbeat"),
  )
  fake.enqueue_text(transport, push("unknown", "ignored"))
  fake.enqueue_text(transport, push("", "op"))
  let received = channel.receive(channel, 1000)
  let assert Ok(Nil) = socket.close(socket)
  fake.shutdown(transport)

  let assert Ok(incoming) = received
  assert incoming.topic == topic
  assert incoming.event == "op"
  assert channel.receive(channel, 1000) == Error(error.ChannelClosed)
}

pub fn leaves_topic_routing_unchanged_without_opt_in_test() -> Nil {
  let transport = fake.start()
  let socket = start_socket(transport, phoenix.codec())
  let channel = join(transport, socket, "1")

  fake.enqueue_text(transport, push("", "ignored"))
  fake.enqueue_text(transport, push(topic, "op"))
  let received = channel.receive(channel, 1000)
  let assert Ok(Nil) = socket.close(socket)
  fake.shutdown(transport)

  let assert Ok(incoming) = received
  assert incoming.event == "op"
}

pub fn rejects_a_second_topic_without_sending_a_join_test() -> Nil {
  let transport = fake.start()
  let socket = start_socket(transport, topicless_codec())
  let _channel = join(transport, socket, "1")
  let before = fake.outbound(transport)
  let result = channel.join(socket, "another", json.object([]), 1000)
  let after = fake.outbound(transport)
  let assert Ok(Nil) = socket.close(socket)
  fake.shutdown(transport)

  assert result == Error(error.TopiclessSocketOccupied(topic))
  assert before == after
}

pub fn rejects_a_second_topic_while_the_first_join_is_pending_test() -> Nil {
  let requests = process.new_subject()
  let results = process.new_subject()
  let events = process.new_subject()
  let connector = fn(_sink) {
    Ok(
      transport.Transport(
        send_text: fn(text) { process.send(requests, text) },
        close: fn() { Ok(Nil) },
      ),
    )
  }
  let assert Ok(socket) =
    socket.test_config(connector, topicless_codec())
    |> socket.with_heartbeat_ms(86_400_000)
    |> socket.start
  process.spawn(fn() {
    let result = socket.join(socket, topic, json.object([]), events, 1000)
    process.send(results, result)
  })
  let assert Ok(_) = process.receive(requests, 1000)
  let second_join = channel.join(socket, "another", json.object([]), 1000)
  let assert Ok(Nil) = socket.close(socket)

  assert second_join == Error(error.TopiclessSocketOccupied(topic))
  assert process.receive(requests, 0) == Error(Nil)
  assert process.receive(results, 1000) == Ok(Error(error.ChannelClosed))
  assert process.receive(events, 1000) == Ok(Error(error.ChannelClosed))
}

pub fn topicless_close_allows_a_fresh_join_test() -> Nil {
  let transport = fake.start()
  let socket = start_socket(transport, topicless_codec())
  let channel = join(transport, socket, "1")

  fake.enqueue_text(transport, push("", phoenix.codec().close_event))
  assert channel.receive(channel, 1000) == Error(error.ChannelClosed)
  let rejoined = join(transport, socket, "2")
  fake.enqueue_text(transport, push("", "op"))
  let received = channel.receive(rejoined, 1000)
  let assert Ok(Nil) = socket.close(socket)
  fake.shutdown(transport)

  let assert Ok(incoming) = received
  assert incoming.event == "op"
  assert channel.receive(channel, 0) == Error(error.Transport(error.Timeout))
}

pub fn stale_join_errors_do_not_close_a_replacement_test() -> Nil {
  let #(socket, requests) = start_controlled_socket()
  assert socket.join(socket, topic, json.object([]), process.new_subject(), 10)
    == Error(error.ReplyTimeout)
  let assert Ok(#(sink, _)) = process.receive(requests, 1000)

  let events = process.new_subject()
  let results = begin_join(socket, "replacement", events)
  let assert Ok(_) = process.receive(requests, 1000)
  let stale_error =
    frame.encode(
      join_ref: None,
      ref: Some("1"),
      topic: "",
      event: phoenix.codec().error_event,
      payload: json.object([]),
    )
  process.send(sink, transport.Text(stale_error))
  accept(sink, "replacement", "2")
  let assert Ok(Ok(_)) = process.receive(results, 1000)

  process.send(sink, transport.Text(stale_error))
  process.send(sink, transport.Text(push("", "op")))
  let received = process.receive(events, 1000)
  let assert Ok(Nil) = socket.close(socket)
  let assert Ok(Ok(incoming)) = received
  assert incoming.event == "op"
  assert incoming.topic == "replacement"
  assert process.receive(events, 1000) == Ok(Error(error.ChannelClosed))
}

pub fn close_during_join_fails_its_waiter_without_harming_a_replacement_test() -> Nil {
  let #(socket, requests) = start_controlled_socket()
  let closed_events = process.new_subject()
  let closed_join = begin_join(socket, topic, closed_events)
  let assert Ok(#(sink, _)) = process.receive(requests, 1000)
  process.send(sink, transport.Text(push("", phoenix.codec().close_event)))
  assert process.receive(closed_join, 500) == Ok(Error(error.ChannelClosed))
  assert process.receive(closed_events, 500) == Ok(Error(error.ChannelClosed))

  let events = process.new_subject()
  let results = begin_join(socket, topic, events)
  let assert Ok(_) = process.receive(requests, 1000)
  accept(sink, topic, "1")
  accept(sink, topic, "2")
  let assert Ok(Ok(joined)) = process.receive(results, 1000)
  assert joined.join_ref == "2"
  process.send(sink, transport.Text(push("", "op")))
  let received = process.receive(events, 1000)
  let assert Ok(Nil) = socket.close(socket)
  let assert Ok(Ok(incoming)) = received
  assert incoming.event == "op"
  assert process.receive(events, 1000) == Ok(Error(error.ChannelClosed))
}

pub fn disconnect_during_join_releases_the_provisional_topic_test() -> Nil {
  assert_failed_join_releases_topic(transport.Closed)
}

pub fn decode_failure_during_join_releases_the_provisional_topic_test() -> Nil {
  assert_failed_join_releases_topic(transport.Text("invalid"))
}

pub fn a_topicless_error_is_not_rejoined_after_reconnect_test() -> Nil {
  let transport = fake.start()
  let socket = start_socket(transport, topicless_codec())
  let channel = join(transport, socket, "1")
  let status = process.new_subject()
  socket.watch(socket, status)

  fake.enqueue_text(transport, push("", phoenix.codec().error_event))
  assert channel.receive(channel, 1000) == Error(error.ChannelClosed)
  let before = fake.outbound(transport)
  fake.enqueue_closed(transport)
  assert process.receive(status, 1000)
    == Ok(socket.Disconnected(error.ChannelClosed))
  let assert Ok(socket.Reconnecting(_, _)) = process.receive(status, 1000)
  assert process.receive(status, 1000) == Ok(socket.Connected)
  let assert Ok(Nil) = socket.close(socket)
  let after = fake.outbound(transport)
  fake.shutdown(transport)

  assert before == after
  assert process.receive(status, 0) == Error(Nil)
  assert channel.receive(channel, 0) == Error(error.Transport(error.Timeout))
}

fn topicless_codec() -> codec.Codec {
  let base = phoenix.codec()
  codec.Codec(
    ..base,
    topicless_events: True,
    matches_reply: fn(incoming: codec.Incoming, reference) {
      incoming.ref == Some(reference)
      && {
        incoming.event == base.reply_event || incoming.event == base.error_event
      }
    },
  )
}

fn start_controlled_socket() -> #(
  socket.Socket,
  process.Subject(#(process.Subject(transport.Frame), String)),
) {
  let requests = process.new_subject()
  let connector = fn(sink) {
    Ok(
      transport.Transport(
        send_text: fn(text) { process.send(requests, #(sink, text)) },
        close: fn() { Ok(Nil) },
      ),
    )
  }
  let assert Ok(socket) =
    socket.test_config(connector, topicless_codec())
    |> socket.with_heartbeat_ms(86_400_000)
    |> socket.with_backoff(
      backoff.default()
      |> backoff.with_initial_ms(1)
      |> backoff.with_jitter(fn(delay) { delay }),
    )
    |> socket.start
  #(socket, requests)
}

fn begin_join(
  socket: socket.Socket,
  topic: String,
  events: process.Subject(socket.Event),
) -> process.Subject(Result(socket.Joined, error.AquamarineError)) {
  let results = process.new_subject()
  process.spawn(fn() {
    let result = socket.join(socket, topic, json.object([]), events, 1000)
    process.send(results, result)
  })
  results
}

fn accept(
  sink: process.Subject(transport.Frame),
  topic: String,
  reference: String,
) -> Nil {
  process.send(
    sink,
    transport.Text(frame.encode_reply(
      join_ref: Some(reference),
      ref: reference,
      topic: topic,
      status: frame.StatusOk,
      response: json.object([]),
    )),
  )
}

fn assert_failed_join_releases_topic(failure: transport.Frame) -> Nil {
  let #(socket, requests) = start_controlled_socket()
  let status = process.new_subject()
  socket.watch(socket, status)
  let results = begin_join(socket, topic, process.new_subject())
  let assert Ok(#(sink, _)) = process.receive(requests, 1000)
  process.send(sink, failure)
  let assert Ok(Error(_)) = process.receive(results, 1000)
  case failure {
    transport.Closed -> {
      let assert Ok(socket.Disconnected(_)) = process.receive(status, 1000)
      let assert Ok(socket.Reconnecting(_, _)) = process.receive(status, 1000)
      assert process.receive(status, 1000) == Ok(socket.Connected)
    }
    transport.Text(_) | transport.Binary(_) -> Nil
  }

  let events = process.new_subject()
  let results = begin_join(socket, "replacement", events)
  let assert Ok(#(sink, request)) = process.receive(requests, 1000)
  let assert Ok(incoming) = phoenix.codec().decode(request)
  assert incoming.topic == "replacement"
  let assert Some(reference) = incoming.ref
  accept(sink, "replacement", reference)
  let assert Ok(Ok(_)) = process.receive(results, 1000)
  let assert Ok(Nil) = socket.close(socket)
  assert process.receive(events, 1000) == Ok(Error(error.ChannelClosed))
}

fn start_socket(
  transport: fake.FakeSocket,
  codec: codec.Codec,
) -> socket.Socket {
  let assert Ok(socket) =
    socket.test_config(fake.connector_for(transport), codec)
    |> socket.with_heartbeat_ms(86_400_000)
    |> socket.with_backoff(
      backoff.default()
      |> backoff.with_initial_ms(1)
      |> backoff.with_jitter(fn(delay) { delay }),
    )
    |> socket.start
  socket
}

fn join(
  transport: fake.FakeSocket,
  socket: socket.Socket,
  reference: String,
) -> channel.Channel {
  fake.enqueue_text_after(
    transport,
    10,
    frame.encode_reply(
      join_ref: Some(reference),
      ref: reference,
      topic: topic,
      status: frame.StatusOk,
      response: json.object([]),
    ),
  )
  let assert Ok(channel) = channel.join(socket, topic, json.object([]), 1000)
  channel
}

fn push(topic: String, event: String) -> String {
  frame.encode(
    join_ref: None,
    ref: None,
    topic: topic,
    event: event,
    payload: json.object([]),
  )
}
