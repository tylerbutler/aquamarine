//// Channel client lifecycle.
////
//// A `Channel` wraps either the callback runtime used by `connect` or the
//// legacy in-memory transport path still used by tests.

import aquamarine/codec.{type Codec, type Incoming}
import aquamarine/error
import aquamarine/heartbeat
import aquamarine/ref
import aquamarine/transport.{type Connector, type Transport}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/json
import gleam/option.{Some}
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
) -> stratus.Next(RuntimeState(state), Command(state)) {
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
              process.send(
                reply_to,
                Error(
                  error.Transport(
                    error.SocketSendFailed(string.inspect(reason)),
                  ),
                ),
              )
              ref.stop(state.counter)
              stratus.stop()
            }
          }
        }
        Error(_) -> {
          process.send(
            reply_to,
            Error(error.InternalError("failed to obtain push ref from counter")),
          )
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

pub opaque type Channel(state) {
  CallbackChannel(
    subject: process.Subject(stratus.InternalMessage(Command(state))),
  )
  LegacyChannel(
    transport: Transport,
    topic: String,
    join_ref: String,
    counter: ref.Counter,
    heartbeat: heartbeat.Heartbeat,
    codec: Codec,
  )
}

type JoinState {
  NotJoined
  Joining(
    reply_to: process.Subject(Result(Nil, error.AquamarineError)),
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
    heartbeat_subject: process.Subject(Command(state)),
    join_state: JoinState,
    heartbeat_ms: Int,
  )
}

type Command(state) {
  StartJoin(reply_to: process.Subject(Result(Nil, error.AquamarineError)))
  Push(
    event: String,
    payload: json.Json,
    reply_to: process.Subject(Result(Nil, error.AquamarineError)),
  )
  Heartbeat
  Close(reply_to: process.Subject(Result(Nil, error.AquamarineError)))
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
  use req <- result.try(request(config))
  use counter <- result.try(start_counter())

  let heartbeat_subject = process.new_subject()
  let runtime =
    RuntimeState(
      config: config,
      handlers: handlers,
      user_state: initial_state,
      counter: counter,
      heartbeat_subject: heartbeat_subject,
      join_state: NotJoined,
      heartbeat_ms: default_heartbeat_ms,
    )

  let selector =
    process.new_selector()
    |> process.select(heartbeat_subject)

  let builder =
    stratus.new_with_initialiser(request: req, init: fn() {
      stratus.initialised(runtime)
      |> stratus.selecting(selector)
      |> Ok
    })
    |> stratus.on_message(loop)
    |> stratus.on_close(handle_transport_closed)

  case stratus.start(builder) {
    Ok(started) -> {
      let reply_to = process.new_subject()
      StartJoin(reply_to)
      |> stratus.to_user_message
      |> process.send(started.data, _)

      case process.receive(reply_to, join_timeout_ms) {
        Ok(Ok(Nil)) -> Ok(CallbackChannel(subject: started.data))
        Ok(Error(err)) -> {
          let _ = request_close(started.data)
          Error(err)
        }
        Error(_) -> {
          let _ = request_close(started.data)
          Error(error.ReplyTimeout)
        }
      }
    }
    Error(err) -> {
      ref.stop(counter)
      Error(map_start_error(err))
    }
  }
}

/// Like [`connect`](#connect) but takes a `Connector` and an explicit
/// heartbeat interval. Used only by tests to plug in the in-memory transport.
@internal
pub fn connect_with(
  connector: Connector,
  topic: String,
  payload: json.Json,
  codec: Codec,
  heartbeat_ms: Int,
) -> Result(Channel(state), error.AquamarineError) {
  use tx <- result.try(connector())

  use counter <- result.try(start_legacy_counter(tx))

  use join_ref <- result.try(next_join_ref(tx, counter))
  let join_frame = codec.encode_join(join_ref, topic, payload)

  use _ <- result.try(send_join(tx, counter, join_frame))

  use _ <- result.try(await_join_reply_with_cleanup(
    tx,
    counter,
    join_ref,
    codec,
  ))

  let send_fn = fn(text: String) -> Result(Nil, Nil) {
    tx.send_text(text)
    |> result.map_error(fn(_) { Nil })
  }

  use hb <- result.try(start_heartbeat(
    tx,
    counter,
    send_fn,
    codec,
    heartbeat_ms,
  ))

  Ok(LegacyChannel(
    transport: tx,
    topic: topic,
    join_ref: join_ref,
    counter: counter,
    heartbeat: hb,
    codec: codec,
  ))
}

/// Push an event into the channel. Refs are assigned automatically.
pub fn push(
  channel: Channel(state),
  event: String,
  payload: json.Json,
) -> Result(Nil, error.AquamarineError) {
  case channel {
    CallbackChannel(subject) -> push_callback_channel(subject, event, payload)
    LegacyChannel(..) -> push_legacy(channel, event, payload)
  }
}

/// Receive the next inbound frame on the legacy test channel.
@internal
pub fn receive(
  channel: Channel(state),
) -> Result(Incoming, error.AquamarineError) {
  case channel {
    CallbackChannel(_) -> Error(error.ChannelClosed)
    LegacyChannel(..) -> do_receive(channel)
  }
}

/// Close the channel and underlying transport. Callback channels ask the
/// Stratus actor to close itself; legacy channels stop their helper actors and
/// close the transport directly.
pub fn close(channel: Channel(state)) -> Result(Nil, error.AquamarineError) {
  case channel {
    CallbackChannel(subject) -> close_callback_channel(subject)
    LegacyChannel(..) -> close_legacy(channel)
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

fn map_start_error(start_error: actor.StartError) -> error.AquamarineError {
  case start_error {
    actor.InitFailed(reason) ->
      case string.contains(reason, "handshake failed with status") {
        True -> error.Transport(error.HandshakeFailed(reason))
        False -> error.Transport(error.SocketConnectionFailed(reason))
      }
    actor.InitTimeout ->
      error.Transport(error.SocketConnectionFailed("connection timed out"))
    actor.InitExited(reason) ->
      error.Transport(error.SocketConnectionFailed(string.inspect(reason)))
  }
}

fn request_close(
  subject: process.Subject(stratus.InternalMessage(Command(state))),
) -> Nil {
  Close(process.new_subject())
  |> stratus.to_user_message
  |> process.send(subject, _)
}

fn close_callback_channel(
  subject: process.Subject(stratus.InternalMessage(Command(state))),
) -> Result(Nil, error.AquamarineError) {
  let reply_to = process.new_subject()
  Close(reply_to)
  |> stratus.to_user_message
  |> process.send(subject, _)

  case process.receive(reply_to, join_timeout_ms) {
    Ok(result) -> result
    Error(_) -> Error(error.ReplyTimeout)
  }
}

fn push_callback_channel(
  subject: process.Subject(stratus.InternalMessage(Command(state))),
  event: String,
  payload: json.Json,
) -> Result(Nil, error.AquamarineError) {
  let reply_to = process.new_subject()
  Push(event:, payload:, reply_to:)
  |> stratus.to_user_message
  |> process.send(subject, _)

  case process.receive(reply_to, join_timeout_ms) {
    Ok(result) -> result
    Error(_) -> Error(error.ReplyTimeout)
  }
}

fn loop(
  state: RuntimeState(state),
  msg: stratus.Message(Command(state)),
  conn: stratus.Connection,
) -> stratus.Next(RuntimeState(state), Command(state)) {
  case msg {
    stratus.User(StartJoin(reply_to)) -> start_join(state, conn, reply_to)
    stratus.Text(text) -> handle_text(state, conn, text)
    stratus.Binary(_) -> stratus.continue(state)
    stratus.User(Push(event:, payload:, reply_to:)) ->
      handle_push(state, conn, event, payload, reply_to)
    stratus.User(Heartbeat) -> stratus.continue(state)
    stratus.User(Close(reply_to)) -> {
      ref.stop(state.counter)
      let result =
        stratus.close(conn, because: stratus.Normal(<<>>))
        |> result.map_error(fn(reason) {
          error.Transport(error.SocketSendFailed(string.inspect(reason)))
        })
      process.send(reply_to, result)
      stratus.stop()
    }
  }
}

fn start_join(
  state: RuntimeState(state),
  conn: stratus.Connection,
  reply_to: process.Subject(Result(Nil, error.AquamarineError)),
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
            RuntimeState(..state, join_state: Joining(reply_to, join_ref)),
          )
        Error(reason) -> {
          let err =
            error.Transport(error.SocketSendFailed(string.inspect(reason)))
          process.send(reply_to, Error(err))
          ref.stop(state.counter)
          stratus.stop()
        }
      }
    }
    Error(_) -> {
      let err = error.InternalError("failed to obtain join ref from counter")
      process.send(reply_to, Error(err))
      ref.stop(state.counter)
      stratus.stop()
    }
  }
}

fn handle_text(
  state: RuntimeState(state),
  _conn: stratus.Connection,
  text: String,
) -> stratus.Next(RuntimeState(state), Command(state)) {
  case state.config.codec.decode(text) {
    Ok(incoming) ->
      case state.join_state {
        Joining(reply_to, join_ref) ->
          handle_join_reply(state, reply_to, join_ref, incoming)
        Joined(_) -> dispatch_incoming(state, incoming)
        NotJoined | Closing -> stratus.continue(state)
      }
    Error(decode_error) ->
      case state.join_state {
        Joining(reply_to, _) -> {
          let err = error.DecodeFailed(decode_error)
          process.send(reply_to, Error(err))
          ref.stop(state.counter)
          stratus.stop()
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
  join_ref: String,
  incoming: Incoming,
) -> stratus.Next(RuntimeState(state), Command(state)) {
  case incoming.event, incoming.ref {
    event, Some(reply_ref)
      if event == state.config.codec.reply_event && reply_ref == join_ref
    -> complete_join(state, reply_to, join_ref, incoming)
    _, _ -> stratus.continue(state)
  }
}

fn complete_join(
  state: RuntimeState(state),
  reply_to: process.Subject(Result(Nil, error.AquamarineError)),
  join_ref: String,
  incoming: Incoming,
) -> stratus.Next(RuntimeState(state), Command(state)) {
  case decode_reply_status(incoming.payload) {
    Ok("ok") ->
      case decode_reply_response(incoming.payload) {
        Ok(reply) -> {
          let next = state.handlers.on_joined(state.user_state, reply)
          case next {
            Continue(user_state) -> {
              let joined_state =
                RuntimeState(
                  ..state,
                  user_state: user_state,
                  join_state: Joined(join_ref),
                )
              process.send(reply_to, Ok(Nil))
              stratus.continue(joined_state)
            }
            Stop -> {
              process.send(reply_to, Error(error.ChannelClosed))
              ref.stop(state.counter)
              stratus.stop()
            }
          }
        }
        Error(_) -> {
          process.send(reply_to, Error(error.JoinRejected("malformed reply")))
          ref.stop(state.counter)
          stratus.stop()
        }
      }
    Ok(other) -> {
      process.send(reply_to, Error(error.JoinRejected(other)))
      ref.stop(state.counter)
      stratus.stop()
    }
    Error(_) -> {
      process.send(reply_to, Error(error.JoinRejected("malformed reply")))
      ref.stop(state.counter)
      stratus.stop()
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
      let next = state.handlers.on_closed(state.user_state)
      apply_next(RuntimeState(..state, join_state: Closing), next)
    }
    event if event == state.config.codec.error_event -> {
      let next = state.handlers.on_error(state.user_state, error.ChannelClosed)
      apply_next(RuntimeState(..state, join_state: Closing), next)
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
    Continue(user_state) ->
      stratus.continue(RuntimeState(..state, user_state: user_state))
    Stop -> {
      ref.stop(state.counter)
      stratus.stop()
    }
  }
}

fn handle_transport_closed(
  state: RuntimeState(state),
  _reason: stratus.CloseReason,
) {
  case state.join_state {
    Joining(reply_to, _) -> process.send(reply_to, Error(error.ChannelClosed))
    Closing -> Nil
    _ -> {
      let _ = state.handlers.on_closed(state.user_state)
      Nil
    }
  }
  ref.stop(state.counter)
  Nil
}

fn push_legacy(
  channel: Channel(state),
  event: String,
  payload: json.Json,
) -> Result(Nil, error.AquamarineError) {
  let assert LegacyChannel(transport:, topic:, join_ref:, counter:, codec:, ..) =
    channel
  use ref <- result.try(
    ref.next(counter)
    |> result.map_error(fn(_) { error.ChannelClosed }),
  )
  let text = codec.encode_push(join_ref, ref, topic, event, payload)
  transport.send_text(text)
}

fn do_receive(
  channel: Channel(state),
) -> Result(Incoming, error.AquamarineError) {
  let assert LegacyChannel(transport:, codec:, ..) = channel
  use frame <- result.try(transport.receive())

  case frame {
    transport.Text(text) ->
      case codec.decode(text) {
        Ok(incoming) -> handle_incoming(channel, incoming)
        Error(err) -> Error(error.DecodeFailed(err))
      }
    transport.Binary(_) -> do_receive(channel)
    transport.Closed -> Error(error.ChannelClosed)
  }
}

fn handle_incoming(
  channel: Channel(state),
  incoming: Incoming,
) -> Result(Incoming, error.AquamarineError) {
  let assert LegacyChannel(codec:, ..) = channel
  case incoming.event {
    e if e == codec.close_event -> Error(error.ChannelClosed)
    e if e == codec.error_event -> Error(error.ChannelClosed)
    e if e == codec.reply_event && incoming.topic == codec.heartbeat_topic ->
      do_receive(channel)
    _ -> Ok(incoming)
  }
}

fn close_legacy(channel: Channel(state)) -> Result(Nil, error.AquamarineError) {
  let assert LegacyChannel(transport:, counter:, heartbeat: hb, ..) = channel
  heartbeat.stop(hb)
  ref.stop(counter)
  transport.close()
}

fn cleanup_connect(tx: Transport, counter: ref.Counter) -> Nil {
  ref.stop(counter)
  let _ = tx.close()
  Nil
}

fn start_legacy_counter(
  tx: Transport,
) -> Result(ref.Counter, error.AquamarineError) {
  case ref.start() {
    Ok(counter) -> Ok(counter)
    Error(_) -> {
      let _ = tx.close()
      Error(error.InternalError("failed to start ref counter actor"))
    }
  }
}

fn next_join_ref(
  tx: Transport,
  counter: ref.Counter,
) -> Result(String, error.AquamarineError) {
  case ref.next(counter) {
    Ok(join_ref) -> Ok(join_ref)
    Error(_) -> {
      cleanup_connect(tx, counter)
      Error(error.InternalError("failed to obtain join ref from counter"))
    }
  }
}

fn send_join(
  tx: Transport,
  counter: ref.Counter,
  join_frame: String,
) -> Result(Nil, error.AquamarineError) {
  case tx.send_text(join_frame) {
    Ok(_) -> Ok(Nil)
    Error(err) -> {
      cleanup_connect(tx, counter)
      Error(err)
    }
  }
}

fn await_join_reply_with_cleanup(
  tx: Transport,
  counter: ref.Counter,
  join_ref: String,
  codec: Codec,
) -> Result(Nil, error.AquamarineError) {
  case await_join_reply(tx, join_ref, codec) {
    Ok(_) -> Ok(Nil)
    Error(err) -> {
      cleanup_connect(tx, counter)
      Error(err)
    }
  }
}

fn start_heartbeat(
  tx: Transport,
  counter: ref.Counter,
  send_fn: fn(String) -> Result(Nil, Nil),
  codec: Codec,
  interval_ms: Int,
) -> Result(heartbeat.Heartbeat, error.AquamarineError) {
  case heartbeat.start(send_fn, interval_ms, counter, codec) {
    Ok(hb) -> Ok(hb)
    Error(_) -> {
      cleanup_connect(tx, counter)
      Error(error.InternalError("failed to start heartbeat actor"))
    }
  }
}

fn await_join_reply(
  tx: Transport,
  join_ref: String,
  codec: Codec,
) -> Result(Nil, error.AquamarineError) {
  use frame <- result.try(tx.receive())

  case frame {
    transport.Text(text) ->
      case codec.decode(text) {
        Ok(incoming) -> match_join_reply(tx, join_ref, incoming, codec)
        Error(err) -> Error(error.DecodeFailed(err))
      }
    transport.Closed -> Error(error.ChannelClosed)
    transport.Binary(_) -> await_join_reply(tx, join_ref, codec)
  }
}

fn match_join_reply(
  tx: Transport,
  join_ref: String,
  incoming: Incoming,
  codec: Codec,
) -> Result(Nil, error.AquamarineError) {
  case incoming.event, incoming.ref {
    event, Some(reply_ref)
      if event == codec.reply_event && reply_ref == join_ref
    ->
      case decode_reply_status(incoming.payload) {
        Ok("ok") -> Ok(Nil)
        Ok(other) -> Error(error.JoinRejected(other))
        Error(_) -> Error(error.JoinRejected("malformed reply"))
      }
    _, _ -> await_join_reply(tx, join_ref, codec)
  }
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
