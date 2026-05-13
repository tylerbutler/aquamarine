//// Monotonic ref counter for channel wire frames.
////
//// Refs are strings. This module wraps a small actor that produces
//// monotonically increasing integers serialised as strings (`"1"`, `"2"`,
//// ...). Used internally by `aquamarine/channel` to assign refs to outbound
//// messages.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/otp/actor
import gleam/result

pub opaque type Counter {
  Counter(subject: Subject(Message))
}

pub opaque type Message {
  Next(reply_to: Subject(String))
  Stop
}

/// Start a new ref counter actor. The first `next` call returns `"1"`.
pub fn start() -> Result(Counter, actor.StartError) {
  case
    actor.new(0)
    |> actor.on_message(handle)
    |> actor.start
  {
    Ok(started) -> Ok(Counter(subject: started.data))
    Error(err) -> Error(err)
  }
}

/// Pull the next ref from the counter.
pub fn next(counter: Counter) -> Result(String, Nil) {
  use pid <- result.try(process.subject_owner(counter.subject))

  let monitor = process.monitor(pid)
  case process.is_alive(pid) {
    False -> {
      process.demonitor_process(monitor)
      Error(Nil)
    }
    True -> {
      let reply_to = process.new_subject()
      process.send(counter.subject, Next(reply_to))

      let reply =
        process.new_selector()
        |> process.select_map(reply_to, Ok)
        |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
        |> process.selector_receive(5000)

      process.demonitor_process(monitor)

      case reply {
        Ok(result) -> result
        Error(_) -> Error(Nil)
      }
    }
  }
}

/// Stop the ref counter actor.
pub fn stop(counter: Counter) -> Nil {
  process.send(counter.subject, Stop)
}

fn handle(state: Int, msg: Message) -> actor.Next(Int, Message) {
  case msg {
    Next(reply_to) -> {
      let next = state + 1
      process.send(reply_to, int.to_string(next))
      actor.continue(next)
    }
    Stop -> actor.stop()
  }
}
