//// Sockets under OTP supervision, and named sockets.
////
//// The point of these tests is not that a supervisor can start something —
//// it is that a *restarted* socket is reachable and usable, which only works
//// because the handle is a name rather than a pid.

import aquamarine/channel
import aquamarine/phoenix
import aquamarine/socket
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import roost/frame as roost_frame
import support/fake_transport as fake

const no_heartbeat: Int = 86_400_000

const test_topic: String = "test:supervised"

pub fn a_supervised_socket_is_usable_test() {
  let f = fake.start()
  let name = socket.new_name("aquamarine_test")
  let _sup = start_supervised(f, name)

  let sock = socket.named(name)
  let ch = join_ok(f, sock, test_topic, "1")

  fake.enqueue_text(f, server_push(test_topic, "hello"))
  let assert Ok(incoming) = channel.receive(ch)
  assert incoming.event == "hello"

  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

/// The whole point of a name: a process that never saw the handle can still
/// reach the socket, without it being threaded through that process's state.
pub fn a_process_that_never_saw_the_handle_can_push_via_the_name_test() {
  let f = fake.start()
  let name = socket.new_name("aquamarine_test")
  let _sup = start_supervised(f, name)

  let sock = socket.named(name)
  let ch = join_ok(f, sock, test_topic, "1")
  let done = process.new_subject()

  // This process is handed a name, not a socket, and not the channel.
  process.spawn(fn() {
    socket.push(
      socket.named(name),
      "1",
      test_topic,
      "from_a_stranger",
      json.object([]),
    )
    process.send(done, Nil)
  })

  let assert Ok(Nil) = process.receive(done, 1000)
  process.sleep(20)

  let assert Ok(sent) = last_outbound(f)
  let assert Ok(decoded) = phoenix.codec().decode(sent)
  assert decoded.event == "from_a_stranger"
  assert decoded.topic == test_topic

  let assert Ok(Nil) = channel.close(ch)
  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

/// Kill the socket and the supervisor brings it back. The restarted socket is
/// a different process, so this only works through the name — and it comes
/// back with nothing joined, which is the property that matters most here.
pub fn killing_the_socket_restarts_it_and_it_is_usable_again_test() {
  let f = fake.start()
  let name = socket.new_name("aquamarine_test")
  let _sup = start_supervised(f, name)

  let sock = socket.named(name)
  let _stale = join_ok(f, sock, test_topic, "1")
  let assert Ok(before) = socket.owner(sock)

  process.kill(before)
  await_new_owner(sock, before, 50)

  let assert Ok(after) = socket.owner(sock)
  assert after != before

  // The restarted socket joined nothing, so the same topic joins cleanly
  // rather than returning AlreadyJoined — and its ref counter started over.
  let fresh = join_ok(f, sock, test_topic, "1")
  fake.enqueue_text(f, server_push(test_topic, "after_restart"))
  let assert Ok(incoming) = channel.receive(fresh)
  assert incoming.event == "after_restart"

  let assert Ok(Nil) = socket.close(sock)
  fake.shutdown(f)
}

// -- helpers ----------------------------------------------------------------

fn start_supervised(
  f: fake.FakeSocket,
  name: socket.Name,
) -> static_supervisor.Supervisor {
  let assert Ok(started) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(socket.supervised_with(
      fake.connector_for(f),
      phoenix.codec(),
      no_heartbeat,
      name,
    ))
    |> static_supervisor.start
  started.data
}

/// Poll until the name resolves to a different process, or give up.
fn await_new_owner(
  sock: socket.Socket,
  previous: process.Pid,
  attempts: Int,
) -> Nil {
  case attempts, socket.owner(sock) {
    0, _ -> Nil
    _, Ok(pid) if pid != previous -> Nil
    _, _ -> {
      process.sleep(20)
      await_new_owner(sock, previous, attempts - 1)
    }
  }
}

fn join_ok(
  f: fake.FakeSocket,
  sock: socket.Socket,
  topic: String,
  expected_ref: String,
) -> channel.Channel {
  fake.enqueue_text_after(
    f,
    10,
    roost_frame.encode_reply(
      join_ref: Some(expected_ref),
      ref: expected_ref,
      topic: topic,
      status: roost_frame.StatusOk,
      response: json.object([]),
    ),
  )
  let assert Ok(ch) = channel.join(sock, topic, json.object([]), 1000)
  ch
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
  case fake.outbound(f) {
    [] -> Error(Nil)
    frames -> last(frames)
  }
}

fn last(frames: List(String)) -> Result(String, Nil) {
  case frames {
    [only] -> Ok(only)
    [_, ..rest] -> last(rest)
    [] -> Error(Nil)
  }
}
