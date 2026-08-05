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
- `src/aquamarine/socket.gleam` is the socket actor. It owns the transport, the ref counter, and the codec. Every inbound frame arrives in its mailbox, is decoded, and is routed — either to a caller blocked on a specific ref, or to the subscriber subject. Errors travel in-band on that subject as `Result(Incoming, AquamarineError)`. Outbound sends are fire-and-forget; a failed send marks the socket gone rather than reporting synchronously.
- Refs are minted inside the actor, in the same message handler that sends the frame carrying them, so ref order and send order cannot diverge. Actor messages are semantic (`Join`, `Push`, `Heartbeat`), not pre-encoded strings — encoding needs a ref, and the ref lives here.
- `src/aquamarine/channel.gleam` owns the channel lifecycle on top of that actor. It starts the socket, joins the topic and blocks on the correlated reply, sends pushes, and cleans up on failures.
- `src/aquamarine/codec.gleam` defines the protocol abstraction. `Codec` supplies decode/encode functions plus protocol event names, so channel logic is not Phoenix-specific.
- `src/aquamarine/phoenix.gleam` adapts `roost/frame` to Aquamarine's `Codec` shape. Phoenix compatibility should generally be implemented here rather than inside `channel.gleam`.
- The heartbeat is a timed self-message inside the socket actor (`process.send_after(self, interval, Heartbeat)`), not a separate process. The actor cancels the pending tick when it stops, so no heartbeat frame outlives a close.
- `src/aquamarine/error.gleam` is the public typed error surface. Public operations return `Result(_, AquamarineError)` and wrap Gluegun failures with `Transport`.

## Project conventions

- The package targets Erlang (`target = "erlang"` in `gleam.toml`); avoid introducing JavaScript-target-only APIs.
- Preserve the codec boundary: protocol-specific frame formats and event names belong in codec adapters, while channel lifecycle and WebSocket behavior belong in `aquamarine/channel`.
- Keep `Channel`, `socket.Socket`, and `socket.Message` opaque so callers cannot construct or depend on internal actor details.
- `connect` must clean up partially started resources on every failure path — a failed join closes the socket it opened.
- Only the process that called `connect` should call `receive` — a subject can only be received from by the process that created it, and `connect` creates the events subject. `push` and `close` are safe from other processes because they are messages to the socket actor.
- `receive` skips non-application frames, binary frames, and heartbeat replies; it turns protocol close/error events into `Error(ChannelClosed)`.
- Tests use gleeunit. The suite entrypoint is `test/aquamarine_test.gleam`, and every test is a public zero-argument function whose name ends in `_test` inside a `*_test` module.
- Codec tests compare against `phoenix_channel_fixtures`; integration tests stand up a supervised Beryl instance (`beryl/supervisor`) behind a Mist listener on an ephemeral port (`mist.port(0)` plus `mist.after_start`).
- Prefer the `assert` keyword for assertions (`assert actual == expected`), matching the existing tests; avoid the deprecated `gleeunit/should` module.
