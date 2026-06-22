---
title: Channel lifecycle
description: Connect, push, handle callbacks, and close — and the ownership rules that go with them.
---

Aquamarine's public surface is intentionally small: a config builder, a
callback builder, and three channel operations. This guide explains what
each one does, what it doesn't do, and which process is allowed to call
it.

## The channel operations

| Function    | What it does                                                       |
| ----------- | ------------------------------------------------------------------ |
| `connect`   | Starts the Stratus actor, joins the topic, waits for the join reply, and starts the heartbeat. |
| `push`      | Encodes an outbound event with a fresh ref and hands it to the transport. Does not wait for a reply. |
| `close`     | Stops the heartbeat and ref actors, then closes the socket.        |

## Callback flow

`connect` takes an initial state and a callback set. Aquamarine keeps that
state inside the channel actor and calls your callbacks as frames arrive.

- `on_joined` runs once the join reply arrives.
- `on_message` runs for application messages.
- `on_error` runs when the runtime sees a transport or decode failure.
- `on_closed` runs when the channel closes.

Each callback returns `aquamarine.continue(state)` to keep the actor
running or `aquamarine.stop(state)` to end it.

## Process ownership

The transport is owned by the process that called `connect`. From there:

- **Callbacks are actor-local.** Aquamarine delivers inbound frames to the
  channel actor, not to a blocking `receive` loop.
- **`push` and `close` are safe from any process.** They send through the
  socket actor, which is fire-and-forget at the call site.

A common pattern is to call `connect` from a per-channel actor, keep state
in the callbacks, and let other parts of your app call `push` or `close`
on the shared `Channel` handle.

## What `connect` actually waits for

`connect` is synchronous. It returns once **all** of the following have
happened, in order:

1. The Stratus-backed WebSocket handshake completes.
2. The ref counter actor starts.
3. The join frame is sent.
4. A `phx_reply` matching the join ref arrives with `status: "ok"`.
5. The heartbeat actor starts.

If any step fails, every resource started so far is torn down before
`connect` returns the error — you never get a half-open channel back.

## What callbacks see

Aquamarine filters transport noise before it reaches your callbacks. It:

- Skips binary frames.
- Skips heartbeat replies (the `phx_reply` on the protocol's heartbeat
  topic).
- Translates protocol close/error events into `on_closed`.
- Delivers other inbound frames as `Incoming` records.

## Refs and replies

`push` assigns a monotonic ref to every outbound message via the internal
[ref counter](/guides/heartbeats-and-refs/). Aquamarine does **not**
correlate replies to pushes for you: if you want request/response
semantics, remember the ref you pushed and match against `incoming.ref`
yourself.

## Closing cleanly

`close` is idempotent at the API level: calling it on an already-closed
channel returns a transport error rather than crashing. It always tries
to stop the heartbeat and ref actors before touching the socket, so even
if the close itself fails you do not leak actors.

## Related

- [Codecs](/guides/codecs/) — how channel logic stays protocol-agnostic.
- [Error handling](/guides/error-handling/) — the errors `connect`,
  `push`, callbacks, and `close` can return.
