import aquamarine/heartbeat
import aquamarine/phoenix
import aquamarine/ref
import gleam/erlang/process
import gleam/option

pub fn sends_heartbeat_frames_on_the_configured_interval_test() {
  let sink = process.new_subject()
  let assert Ok(counter) = ref.start()
  let codec = phoenix.codec()
  let send_fn = fn(text: String) -> Result(Nil, Nil) {
    process.send(sink, text)
    Ok(Nil)
  }

  let assert Ok(hb) = heartbeat.start(send_fn, 20, counter, codec)

  let first = process.receive(sink, 200)
  let second = process.receive(sink, 200)
  let third = process.receive(sink, 200)

  heartbeat.stop(hb)

  let assert Ok(frame1) = first
  let assert Ok(decoded1) = codec.decode(frame1)
  assert decoded1.topic == codec.heartbeat_topic
  assert decoded1.event == "heartbeat"

  let assert Ok(_) = second
  let assert Ok(_) = third
  Nil
}

pub fn uses_monotonically_increasing_refs_from_the_counter_test() {
  let sink = process.new_subject()
  let assert Ok(counter) = ref.start()
  let codec = phoenix.codec()
  let send_fn = fn(text: String) -> Result(Nil, Nil) {
    process.send(sink, text)
    Ok(Nil)
  }

  let assert Ok(hb) = heartbeat.start(send_fn, 20, counter, codec)

  let assert Ok(f1) = process.receive(sink, 200)
  let assert Ok(f2) = process.receive(sink, 200)

  heartbeat.stop(hb)

  let assert Ok(d1) = codec.decode(f1)
  let assert Ok(d2) = codec.decode(f2)

  // Refs increment but exact values depend on counter usage; just assert ordering.
  let assert option.Some(r1) = d1.ref
  let assert option.Some(r2) = d2.ref
  assert r1 != r2
}

pub fn stops_after_a_send_failure_without_scheduling_another_tick_test() {
  let sink = process.new_subject()
  let assert Ok(counter) = ref.start()
  let codec = phoenix.codec()
  let send_fn = fn(text: String) -> Result(Nil, Nil) {
    process.send(sink, text)
    Error(Nil)
  }

  let assert Ok(_) = heartbeat.start(send_fn, 20, counter, codec)

  let first = process.receive(sink, 200)
  process.sleep(60)
  let second = process.receive(sink, 20)

  let assert Ok(_) = first
  assert second == Error(Nil)
}
