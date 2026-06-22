//// Channel client lifecycle for the callback runtime used by `connect`.

import aquamarine/codec.{type Codec, type Incoming}
import aquamarine/error
import aquamarine/ref
import gleam/bool
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/json
import gleam/option.{None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import stratus

pub type Config {
  Config(
    host: String,
    port: Int,
    path: String,
    topic: String,
    payload: json.Json,
    codec: Codec,
  )
}

fn handle_push(
  state: RuntimeState(state),
  conn: stratus.Connection,
  event: String,
  payload: json.Json,
  reply_to: process.Subject(Result(Nil, error.AquamarineError)),
  cancel: CancelToken,
) -> stratus.Next(RuntimeState(state), Command(state)) {
  use <- bool.guard(when: !claim_cancel_token(cancel), return: {
    stratus.continue(state)
  })

  case state.join_state {
    Joined(join_ref) ->
      case ref.next(state.counter) {
        Ok(push_ref) -> {
          let frame =
            state.config.codec.encode_push(
              join_ref,
              push_ref,
              state.config.topic,
              event,
              payload,
            )
          case stratus.send_text_message(conn, frame) {
            Ok(Nil) -> {
              process.send(reply_to, Ok(Nil))
              stratus.continue(state)
            }
            Error(reason) -> {
              let err =
                error.Transport(error.SocketSendFailed(string.inspect(reason)))
              process.send(reply_to, Error(err))
              notify_terminal_error(state, err)
              ref.stop(state.counter)
              stratus.stop()
            }
          }
        }
        Error(_) -> {
          let err =
            error.InternalError("failed to obtain push ref from counter")
          process.send(reply_to, Error(err))
          notify_terminal_error(state, err)
          ref.stop(state.counter)
          stratus.stop()
        }
      }
    _ -> {
      process.send(reply_to, Error(error.ChannelClosed))
      stratus.continue(state)
    }
  }
}

fn handle_heartbeat(
  state: RuntimeState(state),
  conn: stratus.Connection,
) -> stratus.Next(RuntimeState(state), Command(state)) {
  case state.join_state {
    Joined(_) ->
      case ref.next(state.counter) {
        Ok(ref_value) -> {
          let result =
            stratus.send_text_message(
              conn,
              state.config.codec.encode_heartbeat(ref_value),
            )
          case result {
            Ok(Nil) -> {
              case state.self_subject {
                Some(subject) -> {
                  let _ =
                    process.send_after(
                      subject,
                      state.heartbeat_ms,
                      stratus.to_user_message(Heartbeat),
                    )
                  stratus.continue(state)
                }
                None -> stratus.continue(state)
              }
            }
            Error(reason) -> {
              let next =
                state.handlers.on_error(
                  state.user_state,
                  error.Transport(
                    error.SocketSendFailed(string.inspect(reason)),
                  ),
                )
              apply_next(state, next)
            }
          }
        }
        Error(_) -> {
          let next =
            state.handlers.on_error(state.user_state, error.ChannelClosed)
          apply_next(state, next)
        }
      }
    _ -> stratus.continue(state)
  }
}

pub type Handlers(state) {
  Handlers(
    on_joined: fn(state, Dynamic) -> Next(state),
    on_message: fn(state, Incoming) -> Next(state),
    on_error: fn(state, error.AquamarineError) -> Next(state),
    on_closed: fn(state) -> Next(state),
  )
}

pub type Next(state) {
  Continue(state)
  Stop
}

const default_heartbeat_ms: Int = 30_000

const join_timeout_ms: Int = 5000

const callback_self_call_message: String = "channel operations cannot be called from channel callbacks"

pub opaque type Channel(state) {
  CallbackChannel(
    pid: process.Pid,
    subject: process.Subject(stratus.InternalMessage(Command(state))),
  )
}

type JoinState {
  NotJoined
  Joining(
    reply_to: process.Subject(Result(Nil, error.AquamarineError)),
    ready_to: process.Subject(Result(Nil, error.AquamarineError)),
    join_ref: String,
  )
  Joined(join_ref: String)
  Closing
}

type RuntimeState(state) {
  RuntimeState(
    config: Config,
    handlers: Handlers(state),
    user_state: state,
    counter: ref.Counter,
    monitor: option.Option(process.Subject(MonitorMessage(state))),
    self_subject: option.Option(
      process.Subject(stratus.InternalMessage(Command(state))),
    ),
    join_state: JoinState,
    heartbeat_ms: Int,
  )
}

@internal
pub opaque type MonitorMessage(state) {
  UserStateChanged(state)
  RuntimeTerminal(TerminalCallback)
  RuntimeStartupComplete
}

type MonitorEvent(state) {
  MonitorCommand(MonitorMessage(state))
  RuntimeDown(process.Down)
}

type TerminalCallback {
  TerminalClosed
  TerminalError(error.AquamarineError)
  StartupFailureReported
}

type MonitorState(state) {
  MonitorState(
    handlers: Handlers(state),
    user_state: state,
    counter: ref.Counter,
    terminal: option.Option(TerminalCallback),
    startup_complete: Bool,
  )
}

type Command(state) {
  StartJoin(
    reply_to: process.Subject(Result(Nil, error.AquamarineError)),
    ready_to: process.Subject(Result(Nil, error.AquamarineError)),
  )
  Push(
    event: String,
    payload: json.Json,
    reply_to: process.Subject(Result(Nil, error.AquamarineError)),
    cancel: CancelToken,
  )
  SetSelfSubject(
    subject: process.Subject(stratus.InternalMessage(Command(state))),
    monitor: process.Subject(MonitorMessage(state)),
    reply_to: process.Subject(Result(Nil, error.AquamarineError)),
  )
  Heartbeat
  Close(
    reply_to: process.Subject(Result(Nil, error.AquamarineError)),
    cancel: CancelToken,
  )
  Shutdown
}

type CancelToken {
  CancelToken(process.Subject(CancelMessage))
}

type CancelMessage {
  Cancel(reply_to: process.Subject(CancelResult))
  Claim(reply_to: process.Subject(Bool))
}

type CancelEvent {
  CancelCommand(CancelMessage)
  CancelCallerDown
}

type CancelResult {
  Cancelled
  AlreadyClaimed
}

pub fn continue(state: state) -> Next(state) {
  Continue(state)
}

pub fn stop() -> Next(state) {
  Stop
}

pub fn config(
  host host: String,
  port port: Int,
  path path: String,
  topic topic: String,
  payload payload: json.Json,
  codec codec: Codec,
) -> Config {
  Config(host:, port:, path:, topic:, payload:, codec:)
}

pub fn handlers(
  on_joined on_joined: fn(state, Dynamic) -> Next(state),
  on_message on_message: fn(state, Incoming) -> Next(state),
  on_error on_error: fn(state, error.AquamarineError) -> Next(state),
  on_closed on_closed: fn(state) -> Next(state),
) -> Handlers(state) {
  Handlers(on_joined:, on_message:, on_error:, on_closed:)
}

pub fn connect(
  config: Config,
  handlers: Handlers(state),
  initial_state: state,
) -> Result(Channel(state), error.AquamarineError) {
  do_connect(config, handlers, initial_state, default_heartbeat_ms)
}

@internal
pub fn connect_with_heartbeat(
  config: Config,
  handlers: Handlers(state),
  initial_state: state,
  heartbeat_ms: Int,
) -> Result(Channel(state), error.AquamarineError) {
  do_connect(config, handlers, initial_state, heartbeat_ms)
}

fn do_connect(
  config: Config,
  handlers: Handlers(state),
  initial_state: state,
  heartbeat_ms: Int,
) -> Result(Channel(state), error.AquamarineError) {
  use req <- result.try(request(config))
  use counter <- result.try(start_counter())

  let builder =
    stratus.new_with_initialiser(request: req, init: fn() {
      let runtime =
        RuntimeState(
          config: config,
          handlers: handlers,
          user_state: initial_state,
          counter: counter,
          monitor: None,
          self_subject: None,
          join_state: NotJoined,
          heartbeat_ms: heartbeat_ms,
        )
      stratus.initialised(runtime)
      |> Ok
    })
    |> stratus.on_message(loop)
    |> stratus.on_close(handle_transport_closed)

  case stratus.start(builder) {
    Ok(started) -> {
      process.unlink(started.pid)
      let monitor_result =
        start_runtime_monitor(started.pid, handlers, initial_state, counter)
      use monitor <- result.try(case monitor_result {
        Ok(monitor) -> Ok(monitor)
        Error(err) -> {
          let _ = request_close(started.data)
          ref.stop(counter)
          Error(err)
        }
      })
      use _ <- result.try(
        call_runtime(started.pid, started.data, fn(reply_to, _cancel) {
          SetSelfSubject(
            subject: started.data,
            monitor: monitor,
            reply_to: reply_to,
          )
        })
        |> result.map_error(fn(err) {
          let _ = request_close(started.data)
          err
        }),
      )

      case call_start_join(started.pid, started.data) {
        Ok(Nil) -> Ok(CallbackChannel(pid: started.pid, subject: started.data))
        Error(err) -> {
          let _ = request_close(started.data)
          Error(err)
        }
      }
    }
    Error(err) -> {
      ref.stop(counter)
      Error(map_start_error(err))
    }
  }
}

/// Push an event into the channel. Refs are assigned automatically.
pub fn push(
  channel: Channel(state),
  event: String,
  payload: json.Json,
) -> Result(Nil, error.AquamarineError) {
  case channel {
    CallbackChannel(pid, subject) ->
      push_callback_channel(pid, subject, event, payload)
  }
}

/// Close the channel and underlying transport. Callback channels ask the
/// Stratus actor to close itself.
pub fn close(channel: Channel(state)) -> Result(Nil, error.AquamarineError) {
  case channel {
    CallbackChannel(pid, subject) -> close_callback_channel(pid, subject)
  }
}

fn request(
  config: Config,
) -> Result(request.Request(String), error.AquamarineError) {
  let url =
    "http://" <> config.host <> ":" <> int.to_string(config.port) <> config.path

  request.to(url)
  |> result.map_error(fn(_) {
    error.Transport(error.InvalidTransportConfig(url))
  })
}

fn start_counter() -> Result(ref.Counter, error.AquamarineError) {
  ref.start()
  |> result.map_error(fn(_) {
    error.InternalError("failed to start ref counter actor")
  })
}

@internal
pub fn map_start_error(start_error: actor.StartError) -> error.AquamarineError {
  case start_error {
    actor.InitFailed(reason) ->
      case is_handshake_failure(reason) {
        True -> error.Transport(error.HandshakeFailed(reason))
        False -> error.Transport(error.SocketConnectionFailed(reason))
      }
    actor.InitTimeout ->
      error.Transport(error.SocketConnectionFailed("connection timed out"))
    actor.InitExited(reason) ->
      error.Transport(error.SocketConnectionFailed(string.inspect(reason)))
  }
}

fn is_handshake_failure(reason: String) -> Bool {
  string.contains(reason, "WebSocket handshake failed with status")
  || {
    string.contains(reason, "WebSocket handshake failed:")
    && !string.contains(reason, "WebSocket handshake failed: Sock(")
  }
}

fn request_close(
  subject: process.Subject(stratus.InternalMessage(Command(state))),
) -> Nil {
  Shutdown
  |> stratus.to_user_message
  |> process.send(subject, _)
}

fn close_callback_channel(
  pid: process.Pid,
  subject: process.Subject(stratus.InternalMessage(Command(state))),
) -> Result(Nil, error.AquamarineError) {
  call_runtime(pid, subject, fn(reply_to, cancel) { Close(reply_to:, cancel:) })
}

fn push_callback_channel(
  pid: process.Pid,
  subject: process.Subject(stratus.InternalMessage(Command(state))),
  event: String,
  payload: json.Json,
) -> Result(Nil, error.AquamarineError) {
  call_runtime(pid, subject, fn(reply_to, cancel) {
    Push(event:, payload:, reply_to:, cancel:)
  })
}

fn call_start_join(
  pid: process.Pid,
  subject: process.Subject(stratus.InternalMessage(Command(state))),
) -> Result(Nil, error.AquamarineError) {
  let monitor = process.monitor(pid)
  use <- bool.guard(when: !process.is_alive(pid), return: {
    process.demonitor_process(monitor:)
    Error(error.ChannelClosed)
  })

  let reply_to = process.new_subject()
  let ready_to = process.new_subject()
  StartJoin(reply_to:, ready_to:)
  |> stratus.to_user_message
  |> process.send(subject, _)

  let join_selector =
    process.new_selector()
    |> process.select(reply_to)
    |> process.select_specific_monitor(monitor, fn(_) {
      Error(error.ChannelClosed)
    })

  case process.selector_receive(join_selector, join_timeout_ms) {
    Error(_) -> {
      process.demonitor_process(monitor:)
      Error(error.ReplyTimeout)
    }
    Ok(Error(err)) -> {
      process.demonitor_process(monitor:)
      Error(err)
    }
    Ok(Ok(Nil)) -> {
      let ready_selector =
        process.new_selector()
        |> process.select(ready_to)
        |> process.select_specific_monitor(monitor, fn(_) {
          Error(error.ChannelClosed)
        })
      let result = process.selector_receive_forever(ready_selector)
      process.demonitor_process(monitor:)
      result
    }
  }
}

fn call_runtime(
  pid: process.Pid,
  subject: process.Subject(stratus.InternalMessage(Command(state))),
  make_command: fn(
    process.Subject(Result(Nil, error.AquamarineError)),
    CancelToken,
  ) -> Command(state),
) -> Result(Nil, error.AquamarineError) {
  use <- bool.guard(when: process.self() == pid, return: {
    Error(error.InternalError(callback_self_call_message))
  })

  let monitor = process.monitor(pid)
  use <- bool.guard(when: !process.is_alive(pid), return: {
    process.demonitor_process(monitor:)
    Error(error.ChannelClosed)
  })

  let reply_to = process.new_subject()
  let cancel = start_cancel_token()
  make_command(reply_to, cancel)
  |> stratus.to_user_message
  |> process.send(subject, _)

  let selector =
    process.new_selector()
    |> process.select(reply_to)
    |> process.select_specific_monitor(monitor, fn(_) {
      let _ = cancel_token(cancel)
      Error(error.ChannelClosed)
    })

  let result = case process.selector_receive(selector, join_timeout_ms) {
    Ok(result) -> {
      let _ = cancel_token(cancel)
      result
    }
    Error(_) -> {
      case cancel_token(cancel) {
        Cancelled -> Error(error.ReplyTimeout)
        AlreadyClaimed -> await_claimed_runtime_reply(reply_to, monitor)
      }
    }
  }
  process.demonitor_process(monitor:)
  result
}

fn start_cancel_token() -> CancelToken {
  let ready = process.new_subject()
  let caller = process.self()
  process.spawn_unlinked(fn() {
    let subject = process.new_subject()
    let caller_monitor = process.monitor(caller)
    process.send(ready, subject)
    cancel_token_loop(subject, caller_monitor, claimed: False)
  })
  let subject = process.receive_forever(ready)
  CancelToken(subject)
}

fn cancel_token_loop(
  subject: process.Subject(CancelMessage),
  caller_monitor: process.Monitor,
  claimed claimed: Bool,
) -> Nil {
  let selector =
    process.new_selector()
    |> process.select_map(subject, CancelCommand)
    |> process.select_specific_monitor(caller_monitor, fn(_) {
      CancelCallerDown
    })

  case process.selector_receive_forever(selector) {
    CancelCommand(Claim(reply_to)) -> {
      process.send(reply_to, !claimed)
      cancel_token_loop(subject, caller_monitor, claimed: True)
    }
    CancelCommand(Cancel(reply_to)) -> {
      process.send(reply_to, case claimed {
        True -> AlreadyClaimed
        False -> Cancelled
      })
      process.demonitor_process(monitor: caller_monitor)
      Nil
    }
    CancelCallerDown -> Nil
  }
}

fn cancel_token(token: CancelToken) -> CancelResult {
  let CancelToken(subject) = token
  case process.subject_owner(subject) {
    Ok(pid) ->
      case process.is_alive(pid) {
        True -> {
          let monitor = process.monitor(pid)
          let reply_to = process.new_subject()
          process.send(subject, Cancel(reply_to))
          let result =
            process.new_selector()
            |> process.select(reply_to)
            |> process.select_specific_monitor(monitor, fn(_) { Cancelled })
            |> process.selector_receive_forever
          process.demonitor_process(monitor:)
          result
        }
        False -> Cancelled
      }
    _ -> Cancelled
  }
}

fn claim_cancel_token(token: CancelToken) -> Bool {
  let CancelToken(subject) = token
  case process.subject_owner(subject) {
    Ok(pid) ->
      case process.is_alive(pid) {
        True -> {
          let monitor = process.monitor(pid)
          let reply_to = process.new_subject()
          process.send(subject, Claim(reply_to))
          let result =
            process.new_selector()
            |> process.select(reply_to)
            |> process.select_specific_monitor(monitor, fn(_) { False })
            |> process.selector_receive_forever
          process.demonitor_process(monitor:)
          result
        }
        False -> False
      }
    _ -> False
  }
}

fn await_claimed_runtime_reply(
  reply_to: process.Subject(Result(Nil, error.AquamarineError)),
  monitor: process.Monitor,
) -> Result(Nil, error.AquamarineError) {
  process.new_selector()
  |> process.select(reply_to)
  |> process.select_specific_monitor(monitor, fn(_) {
    Error(error.ChannelClosed)
  })
  |> process.selector_receive_forever
}

fn loop(
  state: RuntimeState(state),
  msg: stratus.Message(Command(state)),
  conn: stratus.Connection,
) -> stratus.Next(RuntimeState(state), Command(state)) {
  case msg {
    stratus.User(StartJoin(reply_to:, ready_to:)) ->
      start_join(state, conn, reply_to, ready_to)
    stratus.User(SetSelfSubject(subject:, monitor:, reply_to:)) -> {
      let state =
        RuntimeState(
          ..state,
          monitor: Some(monitor),
          self_subject: Some(subject),
        )
      process.send(reply_to, Ok(Nil))
      stratus.continue(state)
    }
    stratus.Text(text) -> handle_text(state, conn, text)
    stratus.Binary(_) -> stratus.continue(state)
    stratus.User(Push(event:, payload:, reply_to:, cancel:)) ->
      handle_push(state, conn, event, payload, reply_to, cancel)
    stratus.User(Heartbeat) -> handle_heartbeat(state, conn)
    stratus.User(Close(reply_to:, cancel:)) -> {
      let closing_state = RuntimeState(..state, join_state: Closing)
      use <- bool.guard(when: !claim_cancel_token(cancel), return: {
        stratus.continue(state)
      })
      let result =
        stratus.close(conn, because: stratus.Normal(<<>>))
        |> result.map_error(fn(reason) {
          error.Transport(error.SocketSendFailed(string.inspect(reason)))
        })
      process.send(reply_to, result)
      ref.stop(closing_state.counter)
      stratus.stop()
    }
    stratus.User(Shutdown) -> {
      let closing_state = RuntimeState(..state, join_state: Closing)
      let _ = stratus.close(conn, because: stratus.Normal(<<>>))
      ref.stop(closing_state.counter)
      stratus.stop()
    }
  }
}

fn start_join(
  state: RuntimeState(state),
  conn: stratus.Connection,
  reply_to: process.Subject(Result(Nil, error.AquamarineError)),
  ready_to: process.Subject(Result(Nil, error.AquamarineError)),
) -> stratus.Next(RuntimeState(state), Command(state)) {
  case ref.next(state.counter) {
    Ok(join_ref) -> {
      let frame =
        state.config.codec.encode_join(
          join_ref,
          state.config.topic,
          state.config.payload,
        )
      case stratus.send_text_message(conn, frame) {
        Ok(Nil) ->
          stratus.continue(
            RuntimeState(
              ..state,
              join_state: Joining(reply_to, ready_to, join_ref),
            ),
          )
        Error(reason) -> {
          let err =
            error.Transport(error.SocketSendFailed(string.inspect(reason)))
          fail_join(state, reply_to, err)
        }
      }
    }
    Error(_) -> {
      let err = error.InternalError("failed to obtain join ref from counter")
      fail_join(state, reply_to, err)
    }
  }
}

fn fail_join(
  state: RuntimeState(state),
  reply_to: process.Subject(Result(Nil, error.AquamarineError)),
  err: error.AquamarineError,
) -> stratus.Next(RuntimeState(state), Command(state)) {
  process.send(reply_to, Error(err))
  ref.stop(state.counter)
  notify_terminal(state, StartupFailureReported)
  stratus.continue(RuntimeState(..state, join_state: Closing))
}

fn handle_text(
  state: RuntimeState(state),
  _conn: stratus.Connection,
  text: String,
) -> stratus.Next(RuntimeState(state), Command(state)) {
  case state.config.codec.decode(text) {
    Ok(incoming) ->
      case state.join_state {
        Joining(reply_to, ready_to, join_ref) ->
          handle_join_reply(state, reply_to, ready_to, join_ref, incoming)
        Joined(_) -> dispatch_incoming(state, incoming)
        NotJoined | Closing -> stratus.continue(state)
      }
    Error(decode_error) ->
      case state.join_state {
        Joining(reply_to, _, _) -> {
          let err = error.DecodeFailed(decode_error)
          fail_join(state, reply_to, err)
        }
        _ -> {
          let next =
            state.handlers.on_error(
              state.user_state,
              error.DecodeFailed(decode_error),
            )
          apply_next(state, next)
        }
      }
  }
}

fn handle_join_reply(
  state: RuntimeState(state),
  reply_to: process.Subject(Result(Nil, error.AquamarineError)),
  ready_to: process.Subject(Result(Nil, error.AquamarineError)),
  join_ref: String,
  incoming: Incoming,
) -> stratus.Next(RuntimeState(state), Command(state)) {
  case incoming.event, incoming.ref {
    event, Some(reply_ref)
      if event == state.config.codec.reply_event && reply_ref == join_ref
    -> complete_join(state, reply_to, ready_to, join_ref, incoming)
    _, _ -> stratus.continue(state)
  }
}

fn complete_join(
  state: RuntimeState(state),
  reply_to: process.Subject(Result(Nil, error.AquamarineError)),
  ready_to: process.Subject(Result(Nil, error.AquamarineError)),
  join_ref: String,
  incoming: Incoming,
) -> stratus.Next(RuntimeState(state), Command(state)) {
  case decode_reply_status(incoming.payload) {
    Ok("ok") ->
      case decode_reply_response(incoming.payload) {
        Ok(reply) -> {
          let joined_state = RuntimeState(..state, join_state: Joined(join_ref))
          case state.self_subject {
            Some(subject) -> {
              let _ =
                process.send_after(
                  subject,
                  state.heartbeat_ms,
                  stratus.to_user_message(Heartbeat),
                )
              Nil
            }
            None -> Nil
          }
          process.send(reply_to, Ok(Nil))
          let next = state.handlers.on_joined(state.user_state, reply)
          case next {
            Continue(user_state) -> {
              let joined_state = set_user_state(joined_state, user_state)
              notify_startup_complete(joined_state)
              process.send(ready_to, Ok(Nil))
              stratus.continue(joined_state)
            }
            Stop -> {
              process.send(ready_to, Error(error.ChannelClosed))
              ref.stop(state.counter)
              stratus.stop()
            }
          }
        }
        Error(_) -> {
          fail_join(state, reply_to, error.JoinRejected("malformed reply"))
        }
      }
    Ok(other) -> {
      fail_join(state, reply_to, error.JoinRejected(other))
    }
    Error(_) -> {
      fail_join(state, reply_to, error.JoinRejected("malformed reply"))
    }
  }
}

fn dispatch_incoming(
  state: RuntimeState(state),
  incoming: Incoming,
) -> stratus.Next(RuntimeState(state), Command(state)) {
  case incoming.event {
    event
      if event == state.config.codec.reply_event
      && incoming.topic == state.config.codec.heartbeat_topic
    -> stratus.continue(state)
    event if event == state.config.codec.close_event -> {
      let closing_state = RuntimeState(..state, join_state: Closing)
      notify_terminal_closed(closing_state)
      ref.stop(closing_state.counter)
      stratus.stop()
    }
    event if event == state.config.codec.error_event -> {
      let closing_state = RuntimeState(..state, join_state: Closing)
      notify_terminal_error(closing_state, error.ChannelClosed)
      ref.stop(closing_state.counter)
      stratus.stop()
    }
    _ -> {
      let next = state.handlers.on_message(state.user_state, incoming)
      apply_next(state, next)
    }
  }
}

fn apply_next(
  state: RuntimeState(state),
  next: Next(state),
) -> stratus.Next(RuntimeState(state), Command(state)) {
  case next {
    Continue(user_state) -> stratus.continue(set_user_state(state, user_state))
    Stop -> {
      ref.stop(state.counter)
      stratus.stop()
    }
  }
}

fn set_user_state(
  state: RuntimeState(state),
  user_state: state,
) -> RuntimeState(state) {
  case state.monitor {
    Some(monitor) -> process.send(monitor, UserStateChanged(user_state))
    None -> Nil
  }
  RuntimeState(..state, user_state: user_state)
}

fn notify_terminal_closed(state: RuntimeState(state)) -> Nil {
  notify_terminal(state, TerminalClosed)
}

fn notify_terminal_error(
  state: RuntimeState(state),
  err: error.AquamarineError,
) -> Nil {
  notify_terminal(state, TerminalError(err))
}

fn notify_terminal(
  state: RuntimeState(state),
  terminal: TerminalCallback,
) -> Nil {
  case state.monitor {
    Some(monitor) -> process.send(monitor, RuntimeTerminal(terminal))
    None -> Nil
  }
}

fn notify_startup_complete(state: RuntimeState(state)) -> Nil {
  case state.monitor {
    Some(monitor) -> process.send(monitor, RuntimeStartupComplete)
    None -> Nil
  }
}

@internal
pub fn start_runtime_monitor(
  pid: process.Pid,
  handlers: Handlers(state),
  initial_state: state,
  counter: ref.Counter,
) -> Result(process.Subject(MonitorMessage(state)), error.AquamarineError) {
  let ready = process.new_subject()
  process.spawn_unlinked(fn() {
    let subject = process.new_subject()
    let monitor = process.monitor(pid)
    case process.is_alive(pid) {
      True -> {
        process.send(ready, Ok(subject))

        let selector =
          process.new_selector()
          |> process.select_map(subject, MonitorCommand)
          |> process.select_specific_monitor(monitor, RuntimeDown)

        monitor_loop(
          MonitorState(
            handlers:,
            user_state: initial_state,
            counter:,
            terminal: None,
            startup_complete: False,
          ),
          selector,
        )
      }
      False -> {
        process.demonitor_process(monitor:)
        process.send(ready, Error(error.ChannelClosed))
      }
    }
  })

  case process.receive(ready, 1000) {
    Ok(result) -> result
    Error(_) ->
      Error(error.InternalError("failed to start runtime monitor actor"))
  }
}

fn monitor_loop(
  state: MonitorState(state),
  selector: process.Selector(MonitorEvent(state)),
) -> Nil {
  case process.selector_receive_forever(selector) {
    MonitorCommand(UserStateChanged(user_state)) ->
      monitor_loop(MonitorState(..state, user_state: user_state), selector)
    MonitorCommand(RuntimeTerminal(terminal)) ->
      monitor_loop(MonitorState(..state, terminal: Some(terminal)), selector)
    MonitorCommand(RuntimeStartupComplete) ->
      monitor_loop(MonitorState(..state, startup_complete: True), selector)
    RuntimeDown(down) -> handle_runtime_down(state, down)
  }
}

fn handle_runtime_down(state: MonitorState(state), down: process.Down) -> Nil {
  ref.stop(state.counter)
  case down {
    process.ProcessDown(reason:, ..) -> handle_runtime_exit(state, reason)
    process.PortDown(reason:, ..) -> handle_runtime_exit(state, reason)
  }
}

fn handle_runtime_exit(
  state: MonitorState(state),
  reason: process.ExitReason,
) -> Nil {
  case reason {
    process.Normal -> handle_terminal_callback(state)
    _ if state.terminal == Some(StartupFailureReported) -> Nil
    _ if !state.startup_complete -> Nil
    process.Killed -> {
      let _ =
        state.handlers.on_error(
          state.user_state,
          error.Transport(error.UnexpectedTransportFailure("killed")),
        )
      Nil
    }
    process.Abnormal(reason) -> {
      let _ =
        state.handlers.on_error(
          state.user_state,
          error.Transport(error.SocketReceiveFailed(string.inspect(reason))),
        )
      Nil
    }
  }
}

fn handle_terminal_callback(state: MonitorState(state)) -> Nil {
  case state.terminal {
    Some(TerminalClosed) -> {
      let _ = state.handlers.on_closed(state.user_state)
      Nil
    }
    Some(TerminalError(err)) -> {
      let _ = state.handlers.on_error(state.user_state, err)
      Nil
    }
    Some(StartupFailureReported) -> Nil
    None -> Nil
  }
}

fn handle_transport_closed(
  state: RuntimeState(state),
  _reason: stratus.CloseReason,
) {
  case state.join_state {
    Joining(reply_to, _, _) ->
      process.send(reply_to, Error(error.ChannelClosed))
    Closing -> Nil
    _ -> notify_terminal_closed(state)
  }
  ref.stop(state.counter)
  Nil
}

fn decode_reply_status(payload: Dynamic) -> Result(String, Nil) {
  let decoder = {
    use status <- decode.field("status", decode.string)
    decode.success(status)
  }
  decode.run(payload, decoder)
  |> result.map_error(fn(_) { Nil })
}

fn decode_reply_response(payload: Dynamic) -> Result(Dynamic, Nil) {
  let decoder = {
    use response <- decode.field("response", decode.dynamic)
    decode.success(response)
  }
  decode.run(payload, decoder)
  |> result.map_error(fn(_) { Nil })
}
