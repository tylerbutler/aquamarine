---
title: Channel lifecycle
description: Connect, push, receive, and close — and the process-ownership rules that go with them.
---

Aquamarine's public surface is intentionally small: four functions that
move a channel through its lifecycle. This guide explains what each one
does, what it doesn't do, and which process is allowed to call it.

## The four operations

| Function    | What it does                                                       |
| ----------- | ------------------------------------------------------------------ |
| `connect`   | Opens the WebSocket, joins the topic, waits for the join reply, starts the heartbeat. |
| `push`      | Encodes an outbound event with a fresh ref and hands it to the transport. Does not wait for a reply. |
| `receive`   | Blocks until the next application-level inbound frame arrives.    |
| `close`     | Stops the heartbeat and ref actors, then closes the socket.        |

## Process ownership

The transport is owned by the process that called `connect`. From there:

- **`receive` is single-owner.** Only the connecting process may call
  `receive`. The transport delivers inbound frames to that process; calling
  `receive` from another process will not see them.
- **`push` and `close` are safe from any process.** They send through the
  socket actor, which is fire-and-forget at the call site.

A common pattern is to call `connect` from a per-channel actor, have that
actor loop on `receive`, and let other parts of your app call `push` or
`close` on the shared `Channel` handle.

## What `connect` actually waits for

`connect` is synchronous. It returns once **all** of the following have
happened, in order:

1. The WebSocket handshake completes.
2. The ref counter actor starts.
3. The join frame is sent.
4. A `phx_reply` matching the join ref arrives with `status: "ok"`.
5. The heartbeat actor starts.

If any step fails, every resource started so far is torn down before
`connect` returns the error — you never get a half-open channel back.

## What `receive` filters out

`receive` is meant to surface only channel activity that callers care
about. It transparently:

- Skips binary frames.
- Skips heartbeat replies (the `phx_reply` on the protocol's heartbeat
  topic).
- Translates protocol close/error events into
  `Error(ChannelClosed)`.
- Returns `Error(ChannelClosed)` if the underlying socket closes.

Everything else — including non-heartbeat `phx_reply` frames — is
returned to the caller as an `Incoming` record.

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
  `push`, `receive`, and `close` can return.
