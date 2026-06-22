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
| `connect`   | Starts the Stratus actor, joins the topic, waits for the join reply, and schedules the heartbeat. |
| `push`      | Encodes an outbound event with a fresh ref and hands it to the transport. Does not wait for a reply. |
| `close`     | Stops the heartbeat and ref actors, then closes the socket.        |

## Callback flow

`connect` takes an initial state and a callback set. Aquamarine keeps that
state inside the channel actor and calls your callbacks as frames arrive.

- `on_joined` runs once the join reply arrives.
- `on_message` runs for application messages.
- `on_error` runs when the runtime sees a transport or decode failure, or a
  protocol error event.
- `on_closed` runs when the peer or protocol closes the channel. It does not
  run for your own `close(channel)` call.

Each callback returns `aquamarine.continue(state)` to keep the actor
running or `aquamarine.stop()` to end it.

## Actor ownership

The channel is owned by the Stratus actor that `connect` starts. From there:

- **Callbacks are actor-local.** Aquamarine delivers inbound frames to the
  channel actor, not to a separate message loop.
- **`push` and `close` are command-style operations on the opaque channel
  handle.** They route through the channel actor instead of relying on caller
  ownership.

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
5. The channel actor schedules the first heartbeat tick.

If any step fails, Aquamarine starts cleanup for every resource opened so far
before `connect` returns the error — you never get a usable half-open channel
back.

## What callbacks see

Aquamarine filters transport noise before it reaches your callbacks. It:

- Skips binary frames.
- Skips heartbeat replies (the `phx_reply` on the protocol's heartbeat
  topic).
- Translates protocol close events into `on_closed`.
- Translates protocol error events into `on_error(ChannelClosed)`.
- Delivers other inbound frames as `Incoming` records.

Terminal callbacks (`on_closed` and protocol/transport terminal `on_error`
callbacks) run after the channel actor has stopped. Their return value is
observational; the channel is already closed.

## Refs and replies

`push` assigns a monotonic ref to every outbound message via the internal
[ref counter](/guides/heartbeats-and-refs/). Aquamarine does **not**
correlate replies to pushes for you: if you want request/response
semantics, remember the ref you pushed and match against `incoming.ref`
yourself.

## Closing cleanly

`close` asks the actor to send a normal close and stop. It does not call your
`on_closed` callback. If the actor is already gone or does not reply in time,
`close` returns `ChannelClosed`, `ReplyTimeout`, or the appropriate error from
the underlying transport. Close is serialized through the channel actor, so any
already-queued heartbeat tick may run first; once close is processed, the
runtime stops its ref and heartbeat state.

## Related

- [Codecs](/guides/codecs/) — how channel logic stays protocol-agnostic.
- [Error handling](/guides/error-handling/) — the errors `connect`,
  `push`, callbacks, and `close` can return.
