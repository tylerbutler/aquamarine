//// The heartbeat is now just a timer: it calls a function on an interval and
//// knows nothing about refs, codecs, or frames. What it triggers — minting a
//// ref and encoding a heartbeat frame — belongs to the socket actor and is
//// covered in `channel_test`.

import aquamarine/heartbeat
import gleam/erlang/process

pub fn ticks_on_the_configured_interval_test() {
  let ticks = process.new_subject()
  let assert Ok(hb) = heartbeat.start(fn() { process.send(ticks, Nil) }, 20)

  let first = process.receive(ticks, 200)
  let second = process.receive(ticks, 200)
  let third = process.receive(ticks, 200)

  heartbeat.stop(hb)

  assert first == Ok(Nil)
  assert second == Ok(Nil)
  assert third == Ok(Nil)
}

pub fn stops_ticking_once_stopped_test() {
  let ticks = process.new_subject()
  let assert Ok(hb) = heartbeat.start(fn() { process.send(ticks, Nil) }, 20)

  let assert Ok(Nil) = process.receive(ticks, 200)
  heartbeat.stop(hb)

  // Drain anything already in flight, then assert the timer is quiet.
  let _ = process.receive(ticks, 40)
  process.sleep(60)
  assert process.receive(ticks, 20) == Error(Nil)
}
