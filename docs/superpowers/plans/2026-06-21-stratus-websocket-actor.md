# Stratus WebSocket Actor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Aquamarine's Gluegun transport with a Stratus-backed, actor-owned channel lifecycle and a callback-driven public API.

**Architecture:** `aquamarine/channel` becomes the owner of a Stratus WebSocket actor. `connect` starts Stratus, sends the channel join from inside the actor loop, waits for that join to complete, then returns an opaque `Channel(state)` handle for `push` and `close` commands. Inbound messages, runtime errors, heartbeat ticks, and closure are handled inside the actor and delivered through typed callbacks.

**Tech Stack:** Gleam on Erlang, Stratus 3.0.0, `gleam_otp` actors, `gleam_erlang/process` subjects/selectors, Roost Phoenix frame codec, Gleeunit, Beryl/Mist integration server.

## Global Constraints

- Target remains Erlang (`target = "erlang"` in `gleam.toml`); do not introduce JavaScript-target APIs.
- Do not support Gluegun and Stratus as parallel production transports.
- Do not expose Stratus connection details in Aquamarine's public API.
- Do not keep protocol-specific Phoenix behavior in the channel runtime.
- Keep `Channel(state)`, `ref.Counter`, `ref.Message`, `heartbeat.Heartbeat`, and `heartbeat.Message` opaque.
- Keep the codec boundary: protocol frame shape, event names, join encoding, push encoding, and decode behavior remain in `aquamarine/codec` and `aquamarine/phoenix`.
- Remove public `receive(channel)` rather than keeping a compatibility wrapper.
- Existing `push` and `close` call sites should remain command-style operations on an opaque channel handle.
- Use Gleeunit 1.11.0 with public `*_test` functions and `gleeunit/should` assertions.
- Use `gleam test -- --test-name-filter=<name>` for targeted tests when possible and `just ci` before final handoff.

---

## File Structure

- Gleeunit migration note: this plan was first drafted with Startest snippets.
  The resolved dependency constraint is Stratus 3.0.0 plus Gleeunit 1.11.0.
  When a later task shows `describe`, `it`, or `startest/expect`, implement the
  same behavior as public Gleeunit `*_test` functions using
  `gleeunit/should.equal`.
- Modify `gleam.toml`: replace the Gluegun dependency with Stratus.
- Delete or stop importing `src/aquamarine/transport.gleam`: the production socket-like seam goes away.
- Modify `src/aquamarine/error.gleam`: replace Gluegun-shaped transport variants with stable Aquamarine categories.
- Modify `src/aquamarine/channel.gleam`: define `Config`, `Handlers(state)`, `Next(state)`, `Channel(state)`, actor state, command messages, Stratus startup, join handling, push, heartbeat, and close.
- Modify `src/aquamarine.gleam`: re-export the new callback API and remove `receive`.
- Keep `src/aquamarine/codec.gleam` unchanged unless implementation reveals a missing codec query that belongs there.
- Keep `src/aquamarine/phoenix.gleam` as the Phoenix adapter; do not move Phoenix event names into `channel.gleam`.
- Keep `src/aquamarine/ref.gleam` unchanged unless channel actor startup requires a smaller internal helper.
- Keep `src/aquamarine/heartbeat.gleam` for now only if tests or downstream users import it; the new channel actor should schedule heartbeat commands directly through Stratus selectors.
- Replace `test/support/fake_transport.gleam` with `test/support/channel_server.gleam`, a Mist/Beryl test server helper that records outbound client frames and can broadcast scripted server frames.
- Rewrite `test/channel_test.gleam` around callback state and the local test server.
- Rewrite `test/integration_test.gleam` around callback state rather than `receive(channel)`.
- Modify `test/error_test.gleam` for the new `TransportError` categories.
- Keep `test/codec_test.gleam`, `test/ref_test.gleam`, and `test/heartbeat_test.gleam` unchanged unless dependency removal forces an import cleanup.
- Modify `README.md`, `AGENTS.md`, `website/src/content/docs/getting-started.md`, `website/src/content/docs/guides/channels.md`, `website/src/content/docs/guides/heartbeats-and-refs.md`, `website/src/content/docs/guides/error-handling.md`, `website/src/content/docs/reference/ecosystem.md`, and `website/src/content/docs/reference/api.md`.

Known Stratus 3.0.0 APIs this plan relies on:

```gleam
stratus.new(request: Request(String), state: state)
stratus.new_with_initialiser(
  request: Request(String),
  init: fn() -> Result(stratus.Initialised(state, user_message), String),
)
stratus.initialised(state)
stratus.selecting(initialised, selector)
stratus.on_message(builder, fn(state, stratus.Message(user_message), stratus.Connection) {
  stratus.continue(state)
})
stratus.on_close(builder, fn(state, stratus.CloseReason) { Nil })
stratus.with_connect_timeout(builder, timeout)
stratus.start(builder)
stratus.to_user_message(user_message)
stratus.send_text_message(conn, text)
stratus.close(conn, because: stratus.Normal(<<"">>))
```

### Task 1: Replace the dependency and error model

**Files:**
- Modify: `gleam.toml:9-15`
- Modify: `src/aquamarine/error.gleam:1-35`
- Modify: `test/error_test.gleam:1-45`

**Interfaces:**
- Consumes: existing `AquamarineError` public type.
- Produces:
  - `pub type TransportError { HandshakeFailed(reason: String) SocketConnectionFailed(reason: String) SocketSendFailed(reason: String) SocketReceiveFailed(reason: String) InvalidTransportConfig(reason: String) UnexpectedTransportFailure(reason: String) }`
  - `pub type AquamarineError { Transport(TransportError) JoinRejected(String) ChannelClosed DecodeFailed(codec.DecodeError) ReplyTimeout InternalError(String) }`

- [ ] **Step 1: Write the failing error-surface test**

Replace `test/error_test.gleam` with:

```gleam
import aquamarine/error
import startest.{describe, it}
import startest/expect

pub fn error_tests() {
  describe("public error surface", [
    it("keeps transport errors in Aquamarine-owned categories", fn() {
      [
        error.HandshakeFailed("bad upgrade"),
        error.SocketConnectionFailed("econnrefused"),
        error.SocketSendFailed("closed"),
        error.SocketReceiveFailed("timeout"),
        error.InvalidTransportConfig("bad request"),
        error.UnexpectedTransportFailure("actor exited"),
      ]
      |> list_all_stable
      |> expect.to_equal(True)
    }),
  ])
}

fn list_all_stable(errors: List(error.TransportError)) -> Bool {
  case errors {
    [] -> True
    [first, ..rest] ->
      case first {
        error.HandshakeFailed(_) -> list_all_stable(rest)
        error.SocketConnectionFailed(_) -> list_all_stable(rest)
        error.SocketSendFailed(_) -> list_all_stable(rest)
        error.SocketReceiveFailed(_) -> list_all_stable(rest)
        error.InvalidTransportConfig(_) -> list_all_stable(rest)
        error.UnexpectedTransportFailure(_) -> list_all_stable(rest)
      }
  }
}
```

- [ ] **Step 2: Run the failing test**

Run: `gleam test -- test/error_test.gleam`

Expected: FAIL with unknown constructors such as `HandshakeFailed`.

- [ ] **Step 3: Replace Gluegun with Stratus in `gleam.toml`**

Change dependencies to:

```toml
[dependencies]
gleam_stdlib = ">= 0.48.0 and < 2.0.0"
gleam_erlang = ">= 1.0.0 and < 2.0.0"
gleam_otp = ">= 1.0.0 and < 2.0.0"
gleam_json = ">= 3.0.0 and < 4.0.0"
stratus = ">= 3.0.0 and < 4.0.0"
roost = { git = "https://github.com/tylerbutler/roost.git", ref = "7dd796e83d8b0fcb8732cfac35707f3fbc8eeaed" }
```

- [ ] **Step 4: Replace `TransportError` in `src/aquamarine/error.gleam`**

Use this `TransportError` definition:

```gleam
pub type TransportError {
  /// The WebSocket upgrade failed or the Stratus actor could not complete startup.
  HandshakeFailed(reason: String)
  /// Opening the underlying socket failed before the channel could join.
  SocketConnectionFailed(reason: String)
  /// Sending a WebSocket frame failed.
  SocketSendFailed(reason: String)
  /// Receiving a WebSocket frame failed after startup.
  SocketReceiveFailed(reason: String)
  /// The host, port, path, scheme, or request configuration was invalid.
  InvalidTransportConfig(reason: String)
  /// A transport failure did not fit a stable public category.
  UnexpectedTransportFailure(reason: String)
}
```

Keep the existing `AquamarineError` constructors:

```gleam
pub type AquamarineError {
  Transport(TransportError)
  JoinRejected(reason: String)
  ChannelClosed
  DecodeFailed(codec.DecodeError)
  ReplyTimeout
  InternalError(reason: String)
}
```

- [ ] **Step 5: Download dependencies and run the targeted test**

Run:

```bash
gleam deps download
gleam test -- test/error_test.gleam
```

Expected: PASS for `test/error_test.gleam`.

- [ ] **Step 6: Commit**

```bash
git add gleam.toml manifest.toml src/aquamarine/error.gleam test/error_test.gleam
git commit -m "feat: define stratus transport errors"
```

### Task 2: Define the callback API without runtime behavior

**Files:**
- Modify: `src/aquamarine/channel.gleam:1-140`
- Modify: `src/aquamarine.gleam:1-40`
- Test: `test/channel_api_test.gleam`
- Modify: `test/aquamarine_test.gleam`

**Interfaces:**
- Consumes: `codec.Codec`, `codec.Incoming`, `error.AquamarineError`.
- Produces:
  - `pub type Config { Config(host: String, port: Int, path: String, topic: String, payload: json.Json, codec: Codec) }`
  - `pub type Handlers(state) { Handlers(on_joined: fn(state, Dynamic) -> Next(state), on_message: fn(state, Incoming) -> Next(state), on_error: fn(state, AquamarineError) -> Next(state), on_closed: fn(state) -> Next(state)) }`
  - `pub type Next(state) { Continue(state) Stop }`
  - `pub opaque type Channel(state)`
  - `pub fn continue(state: state) -> Next(state)`
  - `pub fn stop() -> Next(state)`
  - `pub fn config(host:, port:, path:, topic:, payload:, codec:) -> Config`
  - `pub fn handlers(on_joined:, on_message:, on_error:, on_closed:) -> Handlers(state)`
  - `pub fn connect(config: Config, handlers: Handlers(state), initial_state: state) -> Result(Channel(state), AquamarineError)`
  - `pub fn push(channel: Channel(state), event: String, payload: json.Json) -> Result(Nil, AquamarineError)`
  - `pub fn close(channel: Channel(state)) -> Result(Nil, AquamarineError)`

- [ ] **Step 1: Add a compile-only API test**

Create `test/channel_api_test.gleam`:

```gleam
import aquamarine
import aquamarine/codec.{type Incoming}
import aquamarine/error.{type AquamarineError}
import aquamarine/phoenix
import gleam/json
import startest.{describe, it}
import startest/expect

type State {
  State(joined: Bool, messages: Int, errors: Int, closed: Bool)
}

pub fn channel_api_tests() {
  describe("callback API", [
    it("builds config and handlers with typed state", fn() {
      let config =
        aquamarine.config(
          host: "127.0.0.1",
          port: 47_891,
          path: "/socket/websocket",
          topic: "test:lobby",
          payload: json.object([]),
          codec: phoenix.codec(),
        )

      let handlers =
        aquamarine.handlers(
          on_joined: on_joined,
          on_message: on_message,
          on_error: on_error,
          on_closed: on_closed,
        )

      let _initial = State(False, 0, 0, False)
      let _ = config
      let _ = handlers

      expect.to_equal(True, True)
    }),
  ])
}

fn on_joined(state: State, _payload) {
  aquamarine.continue(State(..state, joined: True))
}

fn on_message(state: State, _incoming: Incoming) {
  aquamarine.continue(State(..state, messages: state.messages + 1))
}

fn on_error(state: State, _err: AquamarineError) {
  aquamarine.continue(State(..state, errors: state.errors + 1))
}

fn on_closed(state: State) {
  aquamarine.continue(State(..state, closed: True))
}
```

Update `test/aquamarine_test.gleam` to include `channel_api_tests()` in the suite:

```gleam
import channel_api_test

pub fn main() {
  startest.run([
    channel_api_test.channel_api_tests(),
    // keep existing test groups below this line
  ])
}
```

If `test/aquamarine_test.gleam` already uses a different list shape, add `channel_api_test.channel_api_tests()` to the existing list without changing the other entries.

- [ ] **Step 2: Run the failing API test**

Run: `gleam test -- test/channel_api_test.gleam`

Expected: FAIL with unknown functions `aquamarine.config`, `aquamarine.handlers`, and `aquamarine.continue`.

- [ ] **Step 3: Add public types and constructors in `src/aquamarine/channel.gleam`**

At the top of `src/aquamarine/channel.gleam`, replace the old `Channel` type and public function signatures with:

```gleam
import aquamarine/codec.{type Codec, type Incoming}
import aquamarine/error.{type AquamarineError}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Subject}
import gleam/json
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

pub type Handlers(state) {
  Handlers(
    on_joined: fn(state, Dynamic) -> Next(state),
    on_message: fn(state, Incoming) -> Next(state),
    on_error: fn(state, AquamarineError) -> Next(state),
    on_closed: fn(state) -> Next(state),
  )
}

pub type Next(state) {
  Continue(state)
  Stop
}

pub opaque type Channel(state) {
  Channel(subject: Subject(stratus.InternalMessage(Command(state))))
}

type Command(state) {
  StartJoin(reply_to: Subject(Result(Nil, AquamarineError)))
  Push(
    event: String,
    payload: json.Json,
    reply_to: Subject(Result(Nil, AquamarineError)),
  )
  Heartbeat
  Close(reply_to: Subject(Result(Nil, AquamarineError)))
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
  on_error on_error: fn(state, AquamarineError) -> Next(state),
  on_closed on_closed: fn(state) -> Next(state),
) -> Handlers(state) {
  Handlers(on_joined:, on_message:, on_error:, on_closed:)
}
```

Temporarily stub `connect`, `push`, and `close` so only the API test compiles:

```gleam
pub fn connect(
  _config: Config,
  _handlers: Handlers(state),
  _initial_state: state,
) -> Result(Channel(state), AquamarineError) {
  Error(error.InternalError("channel runtime not implemented"))
}

pub fn push(
  _channel: Channel(state),
  _event: String,
  _payload: json.Json,
) -> Result(Nil, AquamarineError) {
  Error(error.ChannelClosed)
}

pub fn close(_channel: Channel(state)) -> Result(Nil, AquamarineError) {
  Error(error.ChannelClosed)
}
```

Import `aquamarine/error as error` for the temporary stubs.

- [ ] **Step 4: Re-export the new API in `src/aquamarine.gleam`**

Replace the old facade with:

```gleam
//// Protocol-agnostic actor-owned channel WebSocket client for Gleam.

import aquamarine/channel
import aquamarine/channel.{type Channel, type Config, type Handlers, type Next}
import aquamarine/codec.{type Codec, type Incoming}
import aquamarine/error.{type AquamarineError}
import gleam/dynamic.{type Dynamic}
import gleam/json

pub fn config(
  host host: String,
  port port: Int,
  path path: String,
  topic topic: String,
  payload payload: json.Json,
  codec codec: Codec,
) -> Config {
  channel.config(host:, port:, path:, topic:, payload:, codec:)
}

pub fn handlers(
  on_joined on_joined: fn(state, Dynamic) -> Next(state),
  on_message on_message: fn(state, Incoming) -> Next(state),
  on_error on_error: fn(state, AquamarineError) -> Next(state),
  on_closed on_closed: fn(state) -> Next(state),
) -> Handlers(state) {
  channel.handlers(on_joined:, on_message:, on_error:, on_closed:)
}

pub fn continue(state: state) -> Next(state) {
  channel.continue(state)
}

pub fn stop() -> Next(state) {
  channel.stop()
}

pub fn connect(
  config: Config,
  handlers: Handlers(state),
  initial_state: state,
) -> Result(Channel(state), AquamarineError) {
  channel.connect(config, handlers, initial_state)
}

pub fn push(
  channel: Channel(state),
  event: String,
  payload: json.Json,
) -> Result(Nil, AquamarineError) {
  channel.push(channel, event, payload)
}

pub fn close(channel: Channel(state)) -> Result(Nil, AquamarineError) {
  channel.close(channel)
}
```

Do not re-export `receive`.

- [ ] **Step 5: Run the API test**

Run: `gleam test -- test/channel_api_test.gleam`

Expected: PASS for the compile-only API test.

- [ ] **Step 6: Commit**

```bash
git add src/aquamarine/channel.gleam src/aquamarine.gleam test/channel_api_test.gleam test/aquamarine_test.gleam
git commit -m "feat: add callback channel api"
```

### Task 3: Start Stratus and wait for join completion

**Files:**
- Modify: `src/aquamarine/channel.gleam`
- Create: `test/support/channel_server.gleam`
- Rewrite first section of `test/channel_test.gleam`

**Interfaces:**
- Consumes: Task 2's `Config`, `Handlers(state)`, `Next(state)`, `Command(state)`, and `Channel(state)`.
- Produces:
  - `type RuntimeState(state)`
  - `fn request(config: Config) -> Result(Request(String), AquamarineError)`
  - `fn loop(state: RuntimeState(state), msg: stratus.Message(Command(state)), conn: stratus.Connection) -> stratus.Next(RuntimeState(state), Command(state))`
  - `fn complete_join(...) -> stratus.Next(RuntimeState(state), Command(state))`

- [ ] **Step 1: Write the successful join callback test**

Replace the old fake-transport connect tests in `test/channel_test.gleam` with this first test:

```gleam
import aquamarine/channel
import aquamarine/codec.{type Incoming}
import aquamarine/error.{type AquamarineError}
import aquamarine/phoenix
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import startest.{describe, it}
import startest/expect
import support/channel_server

type TestEvent {
  Joined(String)
  Message(String)
  ErrorSeen(AquamarineError)
  Closed
}

type State {
  State(events: process.Subject(TestEvent))
}

const test_topic: String = "test:lobby"

pub fn channel_tests() {
  describe("channel actor", [
    it("connect waits for join and calls on_joined", fn() {
      let events = process.new_subject()
      let server = channel_server.start(47_891)
      channel_server.register_ok(server, test_topic, json.object([
        #("welcome", json.string("ok")),
      ]))

      let assert Ok(ch) =
        channel.connect(
          channel.config(
            host: "127.0.0.1",
            port: 47_891,
            path: "/socket/websocket",
            topic: test_topic,
            payload: json.object([]),
            codec: phoenix.codec(),
          ),
          handlers(events),
          State(events),
        )

      let assert Ok(Joined(value)) = process.receive(events, 1000)
      value |> expect.to_equal("ok")

      let assert Ok(Nil) = channel.close(ch)
      channel_server.stop(server)
    }),
  ])
}

fn handlers(events) {
  channel.handlers(
    on_joined: fn(state, payload) {
      let decoder = decode.field("welcome", decode.string)
      let value =
        decode.run(payload, decoder)
        |> result.unwrap("missing")
      process.send(events, Joined(value))
      channel.continue(state)
    },
    on_message: fn(state, incoming: Incoming) {
      process.send(events, Message(incoming.event))
      channel.continue(state)
    },
    on_error: fn(state, err) {
      process.send(events, ErrorSeen(err))
      channel.continue(state)
    },
    on_closed: fn(state) {
      process.send(events, Closed)
      channel.continue(state)
    },
  )
}
```

Add missing imports exactly as the compiler reports them; this test uses `gleam/result` for `result.unwrap`.

- [ ] **Step 2: Add the local server helper**

Create `test/support/channel_server.gleam`:

```gleam
import beryl
import beryl/channel as bchannel
import beryl/transport/mist as mist_transport
import beryl/wire
import gleam/bytes_tree
import gleam/erlang/process.{type Subject}
import gleam/http/response
import gleam/json
import gleam/option.{type Option, Some}
import mist

pub opaque type Server {
  Server(channels: beryl.Channels, mist: mist.Started)
}

pub fn start(port: Int) -> Server {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))

  let handler = fn(req) {
    mist_transport.upgrade(
      req,
      channels,
      mist_transport.default_config("/socket/websocket"),
      fn() {
        response.new(404)
        |> response.set_body(mist.Bytes(bytes_tree.new()))
      },
    )
  }

  let assert Ok(server) =
    mist.new(handler)
    |> mist.port(port)
    |> mist.start

  Server(channels:, mist: server)
}

pub fn register_ok(server: Server, topic: String, reply: json.Json) -> Nil {
  let channel =
    bchannel.new(fn(_topic, _payload, sock) {
      bchannel.JoinOk(reply: Some(reply), socket: sock)
    })

  let assert Ok(_) = beryl.register(server.channels, topic, channel)
  Nil
}

pub fn register_rejected(server: Server, topic: String) -> Nil {
  let channel =
    bchannel.new(fn(_topic, _payload, _sock) {
      bchannel.JoinError(reason: bchannel.error("nope"))
    })

  let assert Ok(_) = beryl.register(server.channels, topic, channel)
  Nil
}

pub fn register_echo(
  server: Server,
  topic: String,
  seen: Subject(String),
) -> Nil {
  let channel =
    bchannel.new(fn(_topic, _payload, sock) {
      bchannel.JoinOk(reply: Some(json.object([])), socket: sock)
    })
    |> bchannel.with_handle_in(fn(event, _payload, sock) {
      process.send(seen, event)
      bchannel.Reply(
        event: "reply",
        payload: json.object([]),
        socket: sock,
      )
    })

  let assert Ok(_) = beryl.register(server.channels, topic, channel)
  Nil
}

pub fn broadcast(
  server: Server,
  topic: String,
  event: String,
  payload: json.Json,
) -> Nil {
  beryl.broadcast(server.channels, topic, event, payload)
}

pub fn stop(_server: Server) -> Nil {
  Nil
}
```

If `mist.Started` has a different public type name, run `gleam check`, read the compiler error, and use the concrete type exposed by the installed Mist version. Do not change the helper's public functions.

- [ ] **Step 3: Run the failing join test**

Run: `gleam test -- test/channel_test.gleam`

Expected: FAIL because `channel.connect` still returns `InternalError("channel runtime not implemented")`.

- [ ] **Step 4: Implement Stratus startup and join command**

In `src/aquamarine/channel.gleam`, add these imports:

```gleam
import aquamarine/ref
import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
```

Add runtime state:

```gleam
const default_heartbeat_ms: Int = 30_000
const join_timeout_ms: Int = 5_000

type JoinState {
  NotJoined
  Joining(reply_to: Subject(Result(Nil, AquamarineError)), join_ref: String)
  Joined(join_ref: String)
  Closing
}

type RuntimeState(state) {
  RuntimeState(
    config: Config,
    handlers: Handlers(state),
    user_state: state,
    counter: ref.Counter,
    heartbeat_subject: Subject(Command(state)),
    join_state: JoinState,
    heartbeat_ms: Int,
  )
}
```

Replace the `connect` stub:

```gleam
pub fn connect(
  config: Config,
  handlers: Handlers(state),
  initial_state: state,
) -> Result(Channel(state), AquamarineError) {
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
    stratus.new_with_initialiser(req, fn() {
      stratus.initialised(runtime)
      |> stratus.selecting(selector)
      |> Ok
    })
    |> stratus.on_message(loop)
    |> stratus.on_close(handle_transport_closed)

  use started <- result.try(
    stratus.start(builder)
    |> result.map_error(fn(err) {
      error.Transport(error.HandshakeFailed(string.inspect(err)))
    }),
  )

  let reply_to = process.new_subject()
  StartJoin(reply_to)
  |> stratus.to_user_message
  |> process.send(started.data, _)

  case process.receive(reply_to, join_timeout_ms) {
    Ok(Ok(Nil)) -> Ok(Channel(subject: started.data))
    Ok(Error(err)) -> {
      Close(process.new_subject())
      |> stratus.to_user_message
      |> process.send(started.data, _)
      Error(err)
    }
    Error(_) -> {
      Close(process.new_subject())
      |> stratus.to_user_message
      |> process.send(started.data, _)
      Error(error.ReplyTimeout)
    }
  }
}
```

Add request and counter helpers:

```gleam
fn request(config: Config) -> Result(Request(String), AquamarineError) {
  let url =
    "http://"
    <> config.host
    <> ":"
    <> int.to_string(config.port)
    <> config.path

  request.to(url)
  |> result.map_error(fn(_) {
    error.Transport(error.InvalidTransportConfig(url))
  })
}

fn start_counter() -> Result(ref.Counter, AquamarineError) {
  ref.start()
  |> result.map_error(fn(_) {
    error.InternalError("failed to start ref counter actor")
  })
}
```

Add loop skeleton and join handling:

```gleam
fn loop(
  state: RuntimeState(state),
  msg: stratus.Message(Command(state)),
  conn: stratus.Connection,
) -> stratus.Next(RuntimeState(state), Command(state)) {
  case msg {
    stratus.User(StartJoin(reply_to)) -> start_join(state, conn, reply_to)
    stratus.Text(text) -> handle_text(state, conn, text)
    stratus.Binary(_) -> stratus.continue(state)
    stratus.User(Push(event:, payload:, reply_to:)) -> {
      process.send(reply_to, Error(error.ChannelClosed))
      stratus.continue(state)
    }
    stratus.User(Heartbeat) -> stratus.continue(state)
    stratus.User(Close(reply_to)) -> {
      ref.stop(state.counter)
      let result =
        stratus.close(conn, because: stratus.Normal(<<"">>))
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
  reply_to: Subject(Result(Nil, AquamarineError)),
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
```

Add text and join reply handling:

```gleam
fn handle_text(
  state: RuntimeState(state),
  conn: stratus.Connection,
  text: String,
) -> stratus.Next(RuntimeState(state), Command(state)) {
  case state.config.codec.decode(text) {
    Ok(incoming) ->
      case state.join_state {
        Joining(reply_to, join_ref) ->
          handle_join_reply(state, conn, reply_to, join_ref, incoming)
        Joined(_) -> stratus.continue(state)
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
          let next = state.handlers.on_error(
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
  _conn: stratus.Connection,
  reply_to: Subject(Result(Nil, AquamarineError)),
  join_ref: String,
  incoming: Incoming,
) -> stratus.Next(RuntimeState(state), Command(state)) {
  case incoming.event, incoming.ref {
    event, Some(reply_ref)
      if event == state.config.codec.reply_event && reply_ref == join_ref
    -> {
      case decode_reply_status(incoming.payload) {
        Ok("ok") -> {
          let next = state.handlers.on_joined(state.user_state, incoming.payload)
          process.send(reply_to, Ok(Nil))
          let joined_state =
            RuntimeState(..state, join_state: Joined(join_ref))
          apply_next(joined_state, next)
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
    _, _ -> stratus.continue(state)
  }
}
```

Move the old `decode_reply_status` helper into the new file unchanged.

Add `apply_next` and close callback:

```gleam
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

fn handle_transport_closed(state: RuntimeState(state), _reason: stratus.CloseReason) {
  let _ = state.handlers.on_closed(state.user_state)
  ref.stop(state.counter)
  Nil
}
```

- [ ] **Step 5: Run the join test**

Run: `gleam test -- test/channel_test.gleam`

Expected: PASS for "connect waits for join and calls on_joined".

- [ ] **Step 6: Commit**

```bash
git add src/aquamarine/channel.gleam test/support/channel_server.gleam test/channel_test.gleam
git commit -m "feat: join channels through stratus"
```

### Task 4: Dispatch runtime messages and errors through callbacks

**Files:**
- Modify: `src/aquamarine/channel.gleam`
- Modify: `test/channel_test.gleam`

**Interfaces:**
- Consumes: Task 3's `handle_text`, `apply_next`, `RuntimeState`.
- Produces:
  - `fn dispatch_incoming(state, incoming) -> stratus.Next(...)`
  - Runtime decode failures call `on_error`.
  - Protocol close/error events call `on_closed` or `on_error`.
  - Heartbeat replies are swallowed.

- [ ] **Step 1: Add failing runtime callback tests**

Append these tests inside `describe("channel actor", [...])`:

```gleam
it("dispatches application messages with updated state", fn() {
  let events = process.new_subject()
  let server = channel_server.start(47_892)
  channel_server.register_ok(server, test_topic, json.object([]))

  let assert Ok(ch) =
    channel.connect(
      channel.config(
        host: "127.0.0.1",
        port: 47_892,
        path: "/socket/websocket",
        topic: test_topic,
        payload: json.object([]),
        codec: phoenix.codec(),
      ),
      handlers(events),
      State(events),
    )

  channel_server.broadcast(
    server,
    test_topic,
    "tick",
    json.object([#("n", json.int(7))]),
  )

  let assert Ok(Message("tick")) = process.receive(events, 1000)

  let assert Ok(Nil) = channel.close(ch)
  channel_server.stop(server)
})
```

Add a test-only malformed sender to `channel_server.gleam`:

```gleam
pub fn send_raw(_server: Server, _topic: String, _raw: String) -> Nil {
  // This helper is intentionally unavailable through Beryl. Runtime malformed
  // frame coverage belongs in the next task's small channel-state unit helper
  // if Beryl cannot emit raw frames.
  Nil
}
```

Do not rely on this no-op for final coverage; it exists only to keep the server helper API stable while the runtime dispatch code lands.

- [ ] **Step 2: Run the failing message test**

Run: `gleam test -- test/channel_test.gleam`

Expected: FAIL because `handle_text` ignores inbound messages after join.

- [ ] **Step 3: Implement `dispatch_incoming`**

In `handle_text`, replace the `Joined(_) -> stratus.continue(state)` branch with:

```gleam
Joined(_) -> dispatch_incoming(state, incoming)
```

Add:

```gleam
fn dispatch_incoming(
  state: RuntimeState(state),
  incoming: Incoming,
) -> stratus.Next(RuntimeState(state), Command(state)) {
  case incoming.event {
    event if event == state.config.codec.close_event -> {
      let next = state.handlers.on_closed(state.user_state)
      apply_next(state, next)
    }
    event if event == state.config.codec.error_event -> {
      let next = state.handlers.on_error(state.user_state, error.ChannelClosed)
      apply_next(state, next)
    }
    event
      if event == state.config.codec.reply_event
      && incoming.topic == state.config.codec.heartbeat_topic
    -> stratus.continue(state)
    _ -> {
      let next = state.handlers.on_message(state.user_state, incoming)
      apply_next(state, next)
    }
  }
}
```

- [ ] **Step 4: Run the message test**

Run: `gleam test -- test/channel_test.gleam`

Expected: PASS for join and application message tests.

- [ ] **Step 5: Add close and error event tests**

Append:

```gleam
it("calls on_closed for server channel close", fn() {
  let events = process.new_subject()
  let server = channel_server.start(47_893)
  channel_server.register_ok(server, test_topic, json.object([]))

  let assert Ok(ch) =
    channel.connect(
      channel.config(
        host: "127.0.0.1",
        port: 47_893,
        path: "/socket/websocket",
        topic: test_topic,
        payload: json.object([]),
        codec: phoenix.codec(),
      ),
      handlers(events),
      State(events),
    )

  channel_server.broadcast(server, test_topic, phoenix.codec().close_event, json.object([]))

  let assert Ok(Closed) = process.receive(events, 1000)

  let assert Ok(Nil) = channel.close(ch)
  channel_server.stop(server)
})
```

- [ ] **Step 6: Run channel tests**

Run: `gleam test -- test/channel_test.gleam`

Expected: PASS for runtime dispatch tests.

- [ ] **Step 7: Commit**

```bash
git add src/aquamarine/channel.gleam test/channel_test.gleam test/support/channel_server.gleam
git commit -m "feat: dispatch channel callbacks"
```

### Task 5: Implement push commands through the channel actor

**Files:**
- Modify: `src/aquamarine/channel.gleam`
- Modify: `test/channel_test.gleam`

**Interfaces:**
- Consumes: Task 3's `Command.Push`, `RuntimeState.join_state`, and `ref.Counter`.
- Produces:
  - `pub fn push(channel: Channel(state), event: String, payload: json.Json) -> Result(Nil, AquamarineError)`
  - Actor-side push encodes `codec.encode_push(join_ref, ref, topic, event, payload)` and sends via Stratus.

- [ ] **Step 1: Add failing push test**

Append:

```gleam
it("push sends encoded frames with fresh refs", fn() {
  let events = process.new_subject()
  let seen = process.new_subject()
  let server = channel_server.start(47_894)
  channel_server.register_echo(server, "test:echo", seen)

  let assert Ok(ch) =
    channel.connect(
      channel.config(
        host: "127.0.0.1",
        port: 47_894,
        path: "/socket/websocket",
        topic: "test:echo",
        payload: json.object([]),
        codec: phoenix.codec(),
      ),
      handlers(events),
      State(events),
    )

  let assert Ok(Nil) =
    channel.push(ch, "say", json.object([#("body", json.string("hi"))]))

  let assert Ok("say") = process.receive(seen, 1000)
  let assert Ok(Message(event)) = process.receive(events, 1000)
  event |> expect.to_equal(phoenix.codec().reply_event)

  let assert Ok(Nil) = channel.close(ch)
  channel_server.stop(server)
})
```

- [ ] **Step 2: Run the failing push test**

Run: `gleam test -- test/channel_test.gleam`

Expected: FAIL because `push` returns `ChannelClosed`.

- [ ] **Step 3: Implement public `push`**

Replace the `push` stub:

```gleam
pub fn push(
  channel: Channel(state),
  event: String,
  payload: json.Json,
) -> Result(Nil, AquamarineError) {
  let reply_to = process.new_subject()
  Push(event:, payload:, reply_to:)
  |> stratus.to_user_message
  |> process.send(channel.subject, _)

  case process.receive(reply_to, 5000) {
    Ok(result) -> result
    Error(_) -> Error(error.ReplyTimeout)
  }
}
```

- [ ] **Step 4: Implement actor-side push**

Replace the `stratus.User(Push(...))` branch in `loop`:

```gleam
stratus.User(Push(event:, payload:, reply_to:)) ->
  handle_push(state, conn, event, payload, reply_to)
```

Add:

```gleam
fn handle_push(
  state: RuntimeState(state),
  conn: stratus.Connection,
  event: String,
  payload: json.Json,
  reply_to: Subject(Result(Nil, AquamarineError)),
) -> stratus.Next(RuntimeState(state), Command(state)) {
  case state.join_state {
    Joined(join_ref) ->
      case ref.next(state.counter) {
        Ok(ref) -> {
          let text =
            state.config.codec.encode_push(
              join_ref,
              ref,
              state.config.topic,
              event,
              payload,
            )
          let result =
            stratus.send_text_message(conn, text)
            |> result.map_error(fn(reason) {
              error.Transport(error.SocketSendFailed(string.inspect(reason)))
            })
          process.send(reply_to, result)
          stratus.continue(state)
        }
        Error(_) -> {
          let err = error.ChannelClosed
          process.send(reply_to, Error(err))
          stratus.continue(state)
        }
      }
    _ -> {
      process.send(reply_to, Error(error.ChannelClosed))
      stratus.continue(state)
    }
  }
}
```

- [ ] **Step 5: Run the push test**

Run: `gleam test -- test/channel_test.gleam`

Expected: PASS for push behavior.

- [ ] **Step 6: Commit**

```bash
git add src/aquamarine/channel.gleam test/channel_test.gleam test/support/channel_server.gleam
git commit -m "feat: send pushes through channel actor"
```

### Task 6: Integrate heartbeat scheduling into the Stratus actor

**Files:**
- Modify: `src/aquamarine/channel.gleam`
- Modify: `test/channel_test.gleam`

**Interfaces:**
- Consumes: `RuntimeState.heartbeat_subject`, `RuntimeState.heartbeat_ms`, `Command.Heartbeat`, and `codec.encode_heartbeat`.
- Produces:
  - Heartbeat timer starts only after successful join.
  - Heartbeat tick asks `ref.Counter` for a fresh ref and sends `codec.encode_heartbeat(ref)` through Stratus.
  - Heartbeat replies are swallowed by `dispatch_incoming`.

- [ ] **Step 1: Add a test-only connect helper with heartbeat interval**

Add this internal function in `src/aquamarine/channel.gleam`:

```gleam
@internal
pub fn connect_with_heartbeat(
  config: Config,
  handlers: Handlers(state),
  initial_state: state,
  heartbeat_ms: Int,
) -> Result(Channel(state), AquamarineError) {
  do_connect(config, handlers, initial_state, heartbeat_ms)
}
```

Change public `connect` to call:

```gleam
pub fn connect(
  config: Config,
  handlers: Handlers(state),
  initial_state: state,
) -> Result(Channel(state), AquamarineError) {
  do_connect(config, handlers, initial_state, default_heartbeat_ms)
}
```

Move the Task 3 `connect` implementation into `do_connect(..., heartbeat_ms)`.

- [ ] **Step 2: Add failing heartbeat test**

Append:

```gleam
it("starts heartbeat after join and swallows heartbeat replies", fn() {
  let events = process.new_subject()
  let seen = process.new_subject()
  let server = channel_server.start(47_895)
  channel_server.register_echo(server, "phoenix", seen)

  let assert Ok(ch) =
    channel.connect_with_heartbeat(
      channel.config(
        host: "127.0.0.1",
        port: 47_895,
        path: "/socket/websocket",
        topic: "phoenix",
        payload: json.object([]),
        codec: phoenix.codec(),
      ),
      handlers(events),
      State(events),
      20,
    )

  let assert Ok("heartbeat") = process.receive(seen, 1000)
  process.receive(events, 50) |> expect.to_equal(Error(Nil))

  let assert Ok(Nil) = channel.close(ch)
  channel_server.stop(server)
})
```

- [ ] **Step 3: Run the failing heartbeat test**

Run: `gleam test -- test/channel_test.gleam`

Expected: FAIL because no heartbeat is sent.

- [ ] **Step 4: Schedule heartbeat after join**

In the successful `Ok("ok")` branch in `handle_join_reply`, before `apply_next`, add:

```gleam
let _ =
  process.send_after(
    state.heartbeat_subject,
    state.heartbeat_ms,
    Heartbeat,
  )
```

- [ ] **Step 5: Implement heartbeat command**

Replace the `stratus.User(Heartbeat)` branch:

```gleam
stratus.User(Heartbeat) -> handle_heartbeat(state, conn)
```

Add:

```gleam
fn handle_heartbeat(
  state: RuntimeState(state),
  conn: stratus.Connection,
) -> stratus.Next(RuntimeState(state), Command(state)) {
  case state.join_state {
    Joined(_) ->
      case ref.next(state.counter) {
        Ok(ref) -> {
          let result =
            stratus.send_text_message(
              conn,
              state.config.codec.encode_heartbeat(ref),
            )
          case result {
            Ok(Nil) -> {
              let _ =
                process.send_after(
                  state.heartbeat_subject,
                  state.heartbeat_ms,
                  Heartbeat,
                )
              stratus.continue(state)
            }
            Error(reason) -> {
              let next =
                state.handlers.on_error(
                  state.user_state,
                  error.Transport(error.SocketSendFailed(string.inspect(reason))),
                )
              apply_next(state, next)
            }
          }
        }
        Error(_) -> {
          let next = state.handlers.on_error(state.user_state, error.ChannelClosed)
          apply_next(state, next)
        }
      }
    _ -> stratus.continue(state)
  }
}
```

- [ ] **Step 6: Run heartbeat test**

Run: `gleam test -- test/channel_test.gleam`

Expected: PASS for heartbeat behavior.

- [ ] **Step 7: Commit**

```bash
git add src/aquamarine/channel.gleam test/channel_test.gleam
git commit -m "feat: run heartbeats in channel actor"
```

### Task 7: Implement close semantics and actor cleanup

**Files:**
- Modify: `src/aquamarine/channel.gleam`
- Modify: `test/channel_test.gleam`

**Interfaces:**
- Consumes: `Command.Close`, `RuntimeState.counter`, Stratus close API.
- Produces:
  - `close(channel)` sends a normal close frame when possible.
  - `close(channel)` stops ref generation and the actor.
  - Subsequent `push` returns `ChannelClosed` or `ReplyTimeout`, never hangs.

- [ ] **Step 1: Add failing close test**

Append:

```gleam
it("close stops the actor and later push does not hang", fn() {
  let events = process.new_subject()
  let server = channel_server.start(47_896)
  channel_server.register_ok(server, test_topic, json.object([]))

  let assert Ok(ch) =
    channel.connect(
      channel.config(
        host: "127.0.0.1",
        port: 47_896,
        path: "/socket/websocket",
        topic: test_topic,
        payload: json.object([]),
        codec: phoenix.codec(),
      ),
      handlers(events),
      State(events),
    )

  let assert Ok(Nil) = channel.close(ch)

  case channel.push(ch, "after_close", json.object([])) {
    Error(error.ChannelClosed) -> Nil
    Error(error.ReplyTimeout) -> Nil
    other -> other |> expect.to_equal(Error(error.ChannelClosed))
  }

  channel_server.stop(server)
})
```

- [ ] **Step 2: Run the close test**

Run: `gleam test -- test/channel_test.gleam`

Expected: FAIL if `close` is still stubbed or later `push` hangs.

- [ ] **Step 3: Implement public `close`**

Replace the `close` stub:

```gleam
pub fn close(channel: Channel(state)) -> Result(Nil, AquamarineError) {
  let reply_to = process.new_subject()
  Close(reply_to)
  |> stratus.to_user_message
  |> process.send(channel.subject, _)

  case process.receive(reply_to, 5000) {
    Ok(result) -> result
    Error(_) -> Error(error.ReplyTimeout)
  }
}
```

- [ ] **Step 4: Harden actor-side close state**

Replace the `Close` branch with:

```gleam
stratus.User(Close(reply_to)) -> {
  ref.stop(state.counter)
  let result =
    stratus.close(conn, because: stratus.Normal(<<"">>))
    |> result.map_error(fn(reason) {
      error.Transport(error.SocketSendFailed(string.inspect(reason)))
    })
  process.send(reply_to, result)
  stratus.stop()
}
```

In any startup failure branch that calls `stratus.stop()`, call `ref.stop(state.counter)` first.

- [ ] **Step 5: Run close test**

Run: `gleam test -- test/channel_test.gleam`

Expected: PASS for close behavior.

- [ ] **Step 6: Commit**

```bash
git add src/aquamarine/channel.gleam test/channel_test.gleam
git commit -m "feat: close channel actor cleanly"
```

### Task 8: Rewrite integration tests around callbacks

**Files:**
- Modify: `test/integration_test.gleam`

**Interfaces:**
- Consumes: public `aquamarine.config`, `aquamarine.handlers`, `aquamarine.connect`, `aquamarine.push`, and `aquamarine.close`.
- Produces: Beryl/Mist end-to-end coverage for join, server push, client push reply, and join rejection without `receive`.

- [ ] **Step 1: Rewrite the server-push integration test**

Replace the first integration test with:

```gleam
it("joins a channel and dispatches a server push", fn() {
  let events = process.new_subject()

  let assert Ok(ch) =
    aquamarine.connect(
      aquamarine.config(
        host: "127.0.0.1",
        port: test_port,
        path: test_path,
        topic: "test:lobby",
        payload: json.object([#("hello", json.bool(True))]),
        codec: phoenix.codec(),
      ),
      integration_handlers(events),
      IntegrationState(events),
    )

  process.sleep(50)

  beryl.broadcast(
    channels,
    "test:lobby",
    "tick",
    json.object([#("n", json.int(42))]),
  )

  let assert Ok(IntegrationMessage(incoming)) = process.receive(events, 1000)
  incoming.event |> expect.to_equal("tick")
  incoming.topic |> expect.to_equal("test:lobby")
  decode_n(incoming.payload) |> expect.to_equal(Ok(42))

  let assert Ok(Nil) = aquamarine.close(ch)
  Nil
})
```

Add helper types and handlers:

```gleam
type IntegrationEvent {
  IntegrationJoined
  IntegrationMessage(Incoming)
  IntegrationError(AquamarineError)
  IntegrationClosed
}

type IntegrationState {
  IntegrationState(events: process.Subject(IntegrationEvent))
}

fn integration_handlers(events) {
  aquamarine.handlers(
    on_joined: fn(state, _payload) {
      process.send(events, IntegrationJoined)
      aquamarine.continue(state)
    },
    on_message: fn(state, incoming) {
      process.send(events, IntegrationMessage(incoming))
      aquamarine.continue(state)
    },
    on_error: fn(state, err) {
      process.send(events, IntegrationError(err))
      aquamarine.continue(state)
    },
    on_closed: fn(state) {
      process.send(events, IntegrationClosed)
      aquamarine.continue(state)
    },
  )
}
```

Import `aquamarine/codec.{type Incoming}` and `aquamarine/error.{type AquamarineError}`.

- [ ] **Step 2: Rewrite the client push integration test**

Replace the second integration test with:

```gleam
it("round-trips a client push through the public facade", fn() {
  let events = process.new_subject()

  let assert Ok(ch) =
    aquamarine.connect(
      aquamarine.config(
        host: "127.0.0.1",
        port: test_port,
        path: test_path,
        topic: "test:echo",
        payload: json.object([]),
        codec: phoenix.codec(),
      ),
      integration_handlers(events),
      IntegrationState(events),
    )

  let assert Ok(Nil) =
    aquamarine.push(
      ch,
      "say",
      json.object([#("body", json.string("hello"))]),
    )

  let assert Ok(IntegrationMessage(incoming)) = process.receive(events, 1000)
  incoming.event |> expect.to_equal(phoenix.codec().reply_event)
  incoming.topic |> expect.to_equal("test:echo")
  decode_body(incoming.payload) |> expect.to_equal(Ok("hello"))

  let assert Ok(Nil) = aquamarine.close(ch)
  Nil
})
```

- [ ] **Step 3: Rewrite join rejection around new config**

Replace the join rejection call with:

```gleam
aquamarine.connect(
  aquamarine.config(
    host: "127.0.0.1",
    port: test_port,
    path: test_path,
    topic: "test:rejected",
    payload: json.object([]),
    codec: phoenix.codec(),
  ),
  integration_handlers(process.new_subject()),
  IntegrationState(process.new_subject()),
)
|> expect.to_equal(Error(error.JoinRejected("error")))
```

- [ ] **Step 4: Run integration tests**

Run: `gleam test -- test/integration_test.gleam`

Expected: PASS for all integration tests.

- [ ] **Step 5: Commit**

```bash
git add test/integration_test.gleam
git commit -m "test: use callbacks in integration tests"
```

### Task 9: Remove Gluegun transport code and receive API references

**Files:**
- Delete: `src/aquamarine/transport.gleam`
- Delete: `test/support/fake_transport.gleam`
- Modify: `src/aquamarine/channel.gleam`
- Modify: `src/aquamarine.gleam`
- Modify: tests that still call `receive`

**Interfaces:**
- Consumes: completed Stratus callback runtime.
- Produces: no production import of Gluegun, no public or internal `receive(channel)` function, no `transport.Transport` test seam.

- [ ] **Step 1: Search for forbidden symbols**

Run:

```bash
rg "gluegun|aquamarine/transport|receive\\(|pub fn receive|fake_transport" src test
```

Expected: matches still exist before cleanup.

- [ ] **Step 2: Delete obsolete files**

Remove:

```bash
rm src/aquamarine/transport.gleam
rm test/support/fake_transport.gleam
```

- [ ] **Step 3: Remove remaining receive calls**

For each test still using `channel.receive` or `aquamarine.receive`, convert it to callback state:

```gleam
let events = process.new_subject()
let assert Ok(ch) = aquamarine.connect(config, integration_handlers(events), IntegrationState(events))
let assert Ok(IntegrationMessage(incoming)) = process.receive(events, 1000)
```

Do not add a compatibility wrapper.

- [ ] **Step 4: Run cleanup search**

Run:

```bash
rg "gluegun|aquamarine/transport|receive\\(|pub fn receive|fake_transport" src test
```

Expected: no matches in `src` or `test` except `process.receive`, `process.selector_receive`, or prose comments that describe historical migration in tests.

- [ ] **Step 5: Run targeted tests**

Run:

```bash
gleam test -- test/channel_test.gleam
gleam test -- test/integration_test.gleam
gleam test -- test/error_test.gleam
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src test
git rm src/aquamarine/transport.gleam test/support/fake_transport.gleam
git commit -m "refactor: remove gluegun receive runtime"
```

### Task 10: Update README, website docs, and repository instructions

**Files:**
- Modify: `README.md`
- Modify: `AGENTS.md`
- Modify: `website/src/content/docs/getting-started.md`
- Modify: `website/src/content/docs/guides/channels.md`
- Modify: `website/src/content/docs/guides/heartbeats-and-refs.md`
- Modify: `website/src/content/docs/guides/error-handling.md`
- Modify: `website/src/content/docs/reference/ecosystem.md`
- Modify: `website/src/content/docs/reference/api.md`

**Interfaces:**
- Consumes: final public API from Tasks 2-9.
- Produces: docs that describe Stratus, actor-owned lifecycle, callback state, `push`, `close`, and the new transport error categories.

- [ ] **Step 1: Update README quick start**

Replace the quick start with:

```markdown
## Quick start

```gleam
import aquamarine
import aquamarine/codec.{type Incoming}
import aquamarine/error.{type AquamarineError}
import aquamarine/phoenix
import gleam/json

type State {
  State(messages: Int)
}

let handlers =
  aquamarine.handlers(
    on_joined: fn(state, _reply_payload) {
      aquamarine.continue(state)
    },
    on_message: fn(state, _incoming: Incoming) {
      aquamarine.continue(State(messages: state.messages + 1))
    },
    on_error: fn(state, _err: AquamarineError) {
      aquamarine.continue(state)
    },
    on_closed: fn(state) {
      aquamarine.continue(state)
    },
  )

let assert Ok(channel) =
  aquamarine.connect(
    aquamarine.config(
      host: "localhost",
      port: 4000,
      path: "/socket/websocket",
      topic: "room:lobby",
      payload: json.object([]),
      codec: phoenix.codec(),
    ),
    handlers,
    State(messages: 0),
  )
```
```

- [ ] **Step 2: Update API reference**

In `website/src/content/docs/reference/api.md`, replace the old `connect` and `receive` section with:

```markdown
```gleam
pub fn config(
  host host: String,
  port port: Int,
  path path: String,
  topic topic: String,
  payload payload: json.Json,
  codec codec: Codec,
) -> Config

pub fn handlers(
  on_joined on_joined: fn(state, Dynamic) -> Next(state),
  on_message on_message: fn(state, Incoming) -> Next(state),
  on_error on_error: fn(state, AquamarineError) -> Next(state),
  on_closed on_closed: fn(state) -> Next(state),
) -> Handlers(state)

pub fn connect(
  config: Config,
  handlers: Handlers(state),
  initial_state: state,
) -> Result(Channel(state), AquamarineError)
```

`connect` starts a Stratus WebSocket actor, sends the channel join, waits for the matching join reply, calls `on_joined`, and returns an opaque channel handle. After startup, inbound messages are delivered to callbacks; there is no `receive(channel)` API.
```

- [ ] **Step 3: Update error-handling docs**

In `website/src/content/docs/guides/error-handling.md`, replace the transport error table with:

```markdown
| Variant | Meaning |
| --- | --- |
| `HandshakeFailed(reason)` | The WebSocket upgrade failed or the Stratus actor could not complete startup. |
| `SocketConnectionFailed(reason)` | Opening the underlying socket failed before the channel could join. |
| `SocketSendFailed(reason)` | Sending a WebSocket frame failed. |
| `SocketReceiveFailed(reason)` | Receiving a WebSocket frame failed after startup. |
| `InvalidTransportConfig(reason)` | The host, port, path, scheme, or request configuration was invalid. |
| `UnexpectedTransportFailure(reason)` | A transport failure did not fit a stable public category. |
```

Replace any `case aquamarine.receive(channel)` example with an `on_error` callback example:

```gleam
on_error: fn(state, err) {
  log_error(err)
  aquamarine.continue(state)
}
```

- [ ] **Step 4: Update ecosystem reference**

In `website/src/content/docs/reference/ecosystem.md`:

```markdown
description: How Aquamarine, Beryl, Phoenix codecs, Stratus, and Roost fit together.
```

Replace the diagram node:

```markdown
Stratus["Stratus<br/>WebSocket actor"]
```

Replace the Gluegun bullet:

```markdown
- **[Stratus](https://github.com/rawhat/stratus)** — the WebSocket actor library Aquamarine uses for connection startup, frame IO, ping/pong handling, and close behavior.
```

Remove the "Transport is fixed" paragraph. Replace it with:

```markdown
- **Runtime is actor-owned.** Aquamarine owns the Stratus actor and exposes channel commands plus callbacks, not a socket transport abstraction.
```

- [ ] **Step 5: Update repository instructions**

In `AGENTS.md`, replace Gluegun-specific architecture bullets with:

```markdown
- `src/aquamarine/channel.gleam` owns the Stratus-backed WebSocket channel actor lifecycle. It starts Stratus, starts the ref counter, sends the join frame, waits for the matching `phx_reply`, schedules heartbeats, sends pushes, dispatches inbound frames to callbacks, and cleans up actors/socket on failures.
- `src/aquamarine/error.gleam` is the public typed error surface. Public startup and command operations return `Result(_, AquamarineError)` and wrap Stratus transport failures in stable Aquamarine-owned `TransportError` categories.
- `receive(channel)` does not exist. Inbound application messages, runtime decode failures, and closure are handled by callbacks supplied to `connect`.
```

- [ ] **Step 6: Search docs for stale terms**

Run:

```bash
rg "Gluegun|receive\\(|blocking receive|process ownership|transport is fixed|fake_transport" README.md AGENTS.md website/src/content/docs
```

Expected: no stale matches except historical migration notes that explicitly say the API was removed.

- [ ] **Step 7: Commit**

```bash
git add README.md AGENTS.md website/src/content/docs
git commit -m "docs: describe stratus callback runtime"
```

### Task 11: Final formatting, strict build, and cleanup

**Files:**
- Modify only files changed by `gleam format`.

**Interfaces:**
- Consumes: all previous tasks.
- Produces: formatted, type-checked, tested code with no stale Gluegun runtime references.

- [ ] **Step 1: Format source and tests**

Run:

```bash
gleam format src test
```

Expected: command exits 0.

- [ ] **Step 2: Run full CI**

Run:

```bash
just ci
```

Expected: `format-check`, `check`, `test`, and `build-strict` all pass.

- [ ] **Step 3: Run docs build if website dependencies are installed**

Run:

```bash
cd website && pnpm build
```

Expected: PASS if `node_modules` exists and Node is >= 22. If dependencies are missing, run `pnpm install` in `website/` first, then rerun `pnpm build`.

- [ ] **Step 4: Final stale-reference search**

Run:

```bash
rg "gluegun|Gluegun|receive\\(|pub fn receive|aquamarine/transport|fake_transport" .
```

Expected: no stale runtime/API matches. Matches in `docs/superpowers/specs/2026-06-21-stratus-websocket-design.md` and this implementation plan are acceptable because they describe the migration.

- [ ] **Step 5: Commit final cleanup**

```bash
git add .
git commit -m "chore: finish stratus migration cleanup"
```

## Self-Review

**Spec coverage:** The plan covers Stratus replacement, actor ownership, opaque `Channel(state)`, callback API, removal of `receive`, push/close command semantics, startup join waiting, heartbeat scheduling, codec boundary preservation, stable transport errors, channel tests, integration tests, and docs updates.

**Placeholder scan:** The plan contains no `TBD`, no "implement later", and no unexplained "add appropriate handling" steps. The only intentionally temporary no-op is explicitly scoped to a test helper transition and is not final coverage.

**Type consistency:** Public types and functions are named consistently across tasks: `Config`, `Handlers(state)`, `Next(state)`, `Channel(state)`, `continue`, `stop`, `config`, `handlers`, `connect`, `push`, and `close`. Actor internals consistently use `Command(state)`, `RuntimeState(state)`, `JoinState`, and Stratus `Message(Command(state))`.
