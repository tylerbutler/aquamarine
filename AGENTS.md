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

- `src/aquamarine.gleam` is intentionally a thin public facade for the one-topic case, re-exporting `connect`, `push`, `push_and_await_reply`, `join_reply`, `receive`, `leave`, and `close`. Multi-topic callers use `aquamarine/socket` and `aquamarine/channel` directly.
- `src/aquamarine/socket.gleam` is the socket actor and public multi-topic API: one connection, many topics. It owns the transport, the ref counter, the codec, the heartbeat, and a routing table `Dict(topic, Subject(Event))`. Every inbound frame arrives in its mailbox, is decoded, and is routed — to a caller blocked on a specific ref, or to the channel joined to that frame's topic. Errors travel in-band on the channel's subject as `Result(Incoming, AquamarineError)`. Outbound sends are fire-and-forget; a failed send marks the socket gone rather than reporting synchronously.
- The codec belongs to the socket, not the channel — the socket must decode every frame to read its topic before it can route, so one socket serves one wire protocol. Frames for a topic nobody joined are dropped with a debug log, never a crash; heartbeat replies arrive on the reserved heartbeat topic and fall out that way, so there is no heartbeat special case in the routing path.
- Close and error events are scoped to their topic: they terminate that channel only, leaving the socket and every other channel alive.
- `socket.supervised` returns a `supervision.ChildSpecification(Socket)` for an OTP tree. Supervised sockets are named (`socket.new_name` / `socket.named`), because a restarted socket is a different process and the name is the only handle that survives. The restart is `Transient`, so a deliberate `close` — which exits normally — is not second-guessed by the supervisor. A restarted socket has **no joined channels** and every prior `Channel` handle is stale; restart is not rejoin.
- Refs are minted inside the actor, in the same message handler that sends the frame carrying them, so ref order and send order cannot diverge. Actor messages are semantic (`Join`, `Push`, `Heartbeat`), not pre-encoded strings — encoding needs a ref, and the ref lives here.
- Reply correlation is a `Dict(ref, Waiter)` in actor state. Matching goes through `codec.matches_reply`, never a direct `incoming.ref` comparison, so refless protocols keep working; a codec that can never match simply lets the caller's timeout take over. A caller that times out sends a cancel so the table cannot grow without bound, and losing the socket fails every waiter.
- `src/aquamarine/channel.gleam` is a handle onto one joined topic: socket, topic, join ref, events subject, and whether it owns the socket. `channel.connect` is the one-call path and owns its socket, so `close` on it closes the connection; `channel.join` on an existing socket does not, so `close` on those is leave-only. `leave` is always leave-only. The socket never auto-closes when the last channel leaves.
- A join registers its route when the join frame is *sent*, not when it is accepted, so a server push arriving before the reply still has somewhere to go. The route is withdrawn if the join is rejected, abandoned, or never sent.
- `src/aquamarine/codec.gleam` defines the protocol abstraction. `Codec` supplies decode/encode functions plus protocol event names, so channel logic is not Phoenix-specific.
- `src/aquamarine/phoenix.gleam` adapts `roost/frame` to Aquamarine's `Codec` shape. Phoenix compatibility should generally be implemented here rather than inside `channel.gleam`.
- The heartbeat is a timed self-message inside the socket actor (`process.send_after(self, interval, Heartbeat)`), not a separate process. The actor cancels the pending tick when it stops, so no heartbeat frame outlives a close.
- `src/aquamarine/error.gleam` is the public typed error surface. Public operations return `Result(_, AquamarineError)` and wrap Gluegun failures with `Transport`.

## Project conventions

- The package targets Erlang (`target = "erlang"` in `gleam.toml`); avoid introducing JavaScript-target-only APIs.
- Preserve the codec boundary: protocol-specific frame formats and event names belong in codec adapters, while channel lifecycle and WebSocket behavior belong in `aquamarine/channel`.
- Keep `Channel`, `socket.Socket`, and `socket.Message` opaque so callers cannot construct or depend on internal actor details.
- `connect` must clean up partially started resources on every failure path — a failed join closes the socket it opened.
- Only the process that called `connect` or `join` should call `receive` — a subject can only be received from by the process that created it, and those are what create the events subject. Everything else is safe from other processes because it is a message to the socket actor.
- `receive` sees only its own topic's frames. Binary frames, and frames for unjoined topics (including heartbeat replies), never reach it; protocol close/error events for its topic become `Error(ChannelClosed)`.
- Tests use gleeunit. The suite entrypoint is `test/aquamarine_test.gleam`, and every test is a public zero-argument function whose name ends in `_test` inside a `*_test` module.
- Codec tests compare against `phoenix_channel_fixtures`; integration tests stand up a supervised Beryl instance (`beryl/supervisor`) behind a Mist listener on an ephemeral port (`mist.port(0)` plus `mist.after_start`).
- Prefer the `assert` keyword for assertions (`assert actual == expected`), matching the existing tests; avoid the deprecated `gleeunit/should` module.
