//// Background heartbeat timer.
////
//// A small actor that calls `tick_fn` every `interval_ms`. It no longer knows
//// anything about refs, codecs, or frames — the socket actor mints the ref
//// and encodes the frame, because it is the process that owns both.
////
//// This module is a thin remnant. Once the timer moves into the socket actor
//// as a self-message it goes away entirely.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor

pub opaque type Heartbeat {
  Heartbeat(subject: Subject(Message))
}

pub opaque type Message {
  Tick
  Stop
}

type State {
  State(self: Subject(Message), tick_fn: fn() -> Nil, interval_ms: Int)
}

/// Start a heartbeat timer. The first tick fires after `interval_ms`.
///
/// `tick_fn` is called from the timer's own process and must not block —
/// it is expected to be a single message to the socket actor.
pub fn start(
  tick_fn tick_fn: fn() -> Nil,
  interval_ms interval_ms: Int,
) -> Result(Heartbeat, actor.StartError) {
  let result =
    actor.new_with_initialiser(5000, fn(self) {
      let _ = process.send_after(self, interval_ms, Tick)
      actor.initialised(State(
        self: self,
        tick_fn: tick_fn,
        interval_ms: interval_ms,
      ))
      |> actor.returning(self)
      |> Ok
    })
    |> actor.on_message(handle)
    |> actor.start

  case result {
    Ok(started) -> Ok(Heartbeat(subject: started.data))
    Error(err) -> Error(err)
  }
}

/// Stop the heartbeat timer. Idempotent — sending `Stop` to an already-stopped
/// actor is a no-op from the caller's perspective.
pub fn stop(hb: Heartbeat) -> Nil {
  process.send(hb.subject, Stop)
}

fn handle(state: State, msg: Message) -> actor.Next(State, Message) {
  case msg {
    Tick -> {
      state.tick_fn()
      let _ = process.send_after(state.self, state.interval_ms, Tick)
      actor.continue(state)
    }
    Stop -> actor.stop()
  }
}
