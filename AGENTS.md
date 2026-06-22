# Repository instructions for Agents

Aquamarine is a Gleam library for an Erlang-targeted, protocol-agnostic Beryl-style WebSocket channel client. The public facade is `src/aquamarine.gleam`; most implementation work lives under `src/aquamarine/`.

## Commands

- Download dependencies: `gleam deps download` or `just deps`
- Build: `gleam build` or `just build`
- Strict build: `gleam build --warnings-as-errors` or `just build-strict`
- Test all: `gleam test` or `just test`
- Test one file: `gleam test -- test/codec_test.gleam`
- Test by name: `gleam test -- --test-name-filter='phoenix codec adapter'`
- Format: `gleam format src test` or `just format`
- Check formatting: `gleam format --check src test` or `just format-check`
- Type check: `gleam check` or `just check`
- Full PR/CI check: `just ci` (`format-check`, `check`, `test`, `build-strict`)
- Build docs: `gleam docs build` or `just docs`

CI currently runs on OTP 28 and Gleam 1.16.0, then executes `gleam deps download`, `gleam test`, and `gleam format --check src test`.

## Architecture

- `src/aquamarine.gleam` is intentionally a thin public facade that re-exports the channel runtime API: `config`, `handlers`, `continue`, `stop`, `connect`, `push`, and `close`.
- `src/aquamarine/channel.gleam` owns the Stratus-backed WebSocket channel lifecycle. It starts Stratus, starts the ref counter, sends the join frame, waits for the matching `phx_reply`, schedules heartbeats inside the channel actor, sends pushes, dispatches inbound frames to callbacks, and cleans up actors/socket on failures.
- `src/aquamarine/codec.gleam` defines the protocol abstraction. `Codec` supplies decode/encode functions plus protocol event names, so channel logic is not Phoenix-specific.
- `src/aquamarine/phoenix.gleam` adapts `roost/frame` to Aquamarine's `Codec` shape. Phoenix compatibility should generally be implemented here rather than inside `channel.gleam`.
- `src/aquamarine/ref.gleam` and `src/aquamarine/heartbeat.gleam` are OTP actor helpers. Refs are monotonic strings produced by a counter actor; the standalone heartbeat helper is kept for its own tests and still encodes a heartbeat frame through the configured codec, but channel lifecycle documentation should describe the current Stratus actor behavior.
- `src/aquamarine/error.gleam` is the public typed error surface. Public operations return `Result(_, AquamarineError)` and wrap Stratus transport failures in stable Aquamarine-owned `TransportError` categories.

## Project conventions

- The package targets Erlang (`target = "erlang"` in `gleam.toml`); avoid introducing JavaScript-target-only APIs.
- Preserve the codec boundary: protocol-specific frame formats and event names belong in codec adapters, while channel lifecycle and WebSocket behavior belong in `aquamarine/channel`.
- Keep `Channel`, `ref.Counter`, `ref.Message`, `heartbeat.Heartbeat`, and `heartbeat.Message` opaque so callers cannot construct or depend on internal actor details.
- `connect` must clean up partially started resources on every failure path. Keep the existing `request_close`, `ref.stop`, monitored call, and startup-suppression pattern intact.
- The callbacks own inbound flow. `push` and `close` are safe from other processes because they send through the socket actor, but callbacks must return `stop` instead of calling `close` on their own channel.
- Callback handlers should keep state via `continue` and end cleanly via `stop`.
- Tests use Gleeunit. The suite entrypoint is `test/aquamarine_test.gleam`, and discovered tests are public functions whose names end in `_test`.
- Codec tests compare against `phoenix_channel_fixtures`; integration tests start a local Beryl server via Mist on a dynamically assigned port.
- Prefer `assert`-style Gleeunit checks and straightforward grouping, matching the existing tests.

<!-- repoverlay:profile:development:begin -->
For any file search or grep in the current git-indexed directory, use fff tools.
<!-- repoverlay:profile:development:end -->
