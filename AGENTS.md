# Repository instructions for Agents

Aquamarine is a Gleam library for an Erlang-targeted, protocol-agnostic Beryl-style WebSocket channel client. The public facade is `src/aquamarine.gleam`; most implementation work lives under `src/aquamarine/`.

## Commands

- Download dependencies: `gleam deps download` or `just deps`
- Build: `gleam build` or `just build`
- Strict build: `gleam build --warnings-as-errors` or `just build-strict`
- Test all: `gleam test` or `just test`
- Test one file: `gleam test -- test/codec_test.gleam`
- Format: `gleam format src test` or `just format`
- Check formatting: `gleam format --check src test` or `just format-check`
- Type check: `gleam check` or `just check`
- Full PR/CI check: `just ci` (`format-check`, `check`, `test`, `build-strict`)
- Build docs: `gleam docs build` or `just docs`

CI currently runs on OTP 28 and Gleam 1.18.1, then executes `gleam deps download`, `gleam test`, and `gleam format --check src test`.

## Architecture

- `src/aquamarine.gleam` is intentionally a thin public facade that re-exports the channel lifecycle: `connect`, `push`, `receive`, and `close`.
- `src/aquamarine/channel.gleam` owns the WebSocket channel lifecycle. It connects through Gluegun, starts the ref counter, sends the join frame, waits for the matching `phx_reply`, starts heartbeats, sends pushes, filters inbound frames, and cleans up actors/socket on failures.
- `src/aquamarine/codec.gleam` defines the protocol abstraction. `Codec` supplies decode/encode functions plus protocol event names, so channel logic is not Phoenix-specific.
- `src/aquamarine/phoenix.gleam` adapts `roost/frame` to Aquamarine's `Codec` shape. Phoenix compatibility should generally be implemented here rather than inside `channel.gleam`.
- `src/aquamarine/ref.gleam` and `src/aquamarine/heartbeat.gleam` are OTP actor helpers. Refs are monotonic strings produced by a counter actor; heartbeat periodically asks that counter for a ref, encodes a heartbeat frame through the configured codec, and calls a supplied send function.
- `src/aquamarine/error.gleam` is the public typed error surface. Public operations return `Result(_, AquamarineError)` and wrap Gluegun failures with `Transport`.

## Project conventions

- The package targets Erlang (`target = "erlang"` in `gleam.toml`); avoid introducing JavaScript-target-only APIs.
- Preserve the codec boundary: protocol-specific frame formats and event names belong in codec adapters, while channel lifecycle and WebSocket behavior belong in `aquamarine/channel`.
- Keep `Channel`, `ref.Counter`, `ref.Message`, `heartbeat.Heartbeat`, and `heartbeat.Message` opaque so callers cannot construct or depend on internal actor details.
- `connect` must clean up partially started resources on every failure path. Existing helpers (`cleanup_connect`, `start_counter`, `send_join`, `await_join_reply_with_cleanup`, `start_heartbeat`) encode that pattern.
- Only the process that called `connect` should call `receive`; `push` and `close` are designed to be safe from other processes because they send through the socket actor.
- `receive` skips non-application frames, binary frames, and heartbeat replies; it turns protocol close/error events into `Error(ChannelClosed)`.
- Tests use gleeunit. The suite entrypoint is `test/aquamarine_test.gleam`, and every test is a public zero-argument function whose name ends in `_test` inside a `*_test` module.
- Codec tests compare against `phoenix_channel_fixtures`; integration tests stand up a supervised Beryl instance (`beryl/supervisor`) behind a Mist listener on an ephemeral port (`mist.port(0)` plus `mist.after_start`).
- Prefer the `assert` keyword for assertions (`assert actual == expected`), matching the existing tests; avoid the deprecated `gleeunit/should` module.
