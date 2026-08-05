---
title: Channel lifecycle
description: Sockets and channels, the operations that move them, and the process-ownership rules that go with them.
---

A **socket** is one WebSocket connection. A **channel** is one topic joined
on it. The socket lives in an OTP actor and owns everything with state; a
`Channel` is a handle holding no connection of its own.

## The operations

| Function | What it does |
| --- | --- |
| `socket.connect` | Opens the connection. No topics are joined yet. |
| `channel.join` | Joins a topic on an existing socket, waits for the reply. |
| `channel.connect` | Both of the above in one call, for the single-topic case. |
| `channel.push` | Encodes an outbound event with a fresh ref and hands it to the socket actor. Fire-and-forget. |
| `channel.push_and_await_reply` | The same, but blocks for the reply carrying that ref. |
| `channel.receive` | Blocks until the next frame for this topic arrives, or the timeout elapses. |
| `channel.leave` | Leaves the topic. Always leave-only. |
| `channel.close` | Leaves the topic, and closes the connection if this channel owns it. |
| `socket.close` | Closes the connection, taking every channel with it. |

Who owns closing the connection is covered in
[One socket, many topics](/guides/multi-topic/#who-closes-the-connection).

## Process ownership

The socket actor owns the transport, the codec, the ref counter, the
heartbeat, and the routing table. No calling process touches the socket.

- **`receive` is single-owner.** Only the process that called `connect` or
  `join` may call `receive`. That process created the events subject, and in
  Gleam a subject can only be received from by its creator. This is not a
  policy, it is how subjects work.
- **Everything else is safe from any process.** `push`,
  `push_and_await_reply`, `leave`, `close`, `socket.watch` — each is a
  message to the socket actor.

A common pattern is to `join` from inside a per-topic actor and let the rest
of the application `push` on the shared `Channel` handle. See
[Choosing your model](/guides/choosing-your-model/).

## What `connect` and `join` wait for

Both are synchronous and return once the server has *accepted* the join:

1. The WebSocket handshake completes (`connect` only).
2. The socket actor mints a join ref and sends the join frame.
3. A reply matching that ref arrives with `status: "ok"`.

If any step fails, `connect` tears down the connection it opened before
returning the error — you never get a half-open channel back. A failed
`join` leaves the socket alone, because it did not open it.

`JoinRejected(reason)` is a real outcome, not an exception: the server saw
your join and turned it down.

What the server answered with is available afterwards from
`channel.join_reply(channel)` — useful for asserting the live server contract
rather than assuming it.

## What arrives at `receive`

Only frames for this channel's topic. Inbound frames are routed by topic, so:

- Frames for other topics go to *their* channels.
- Frames for a topic nobody joined are dropped with a debug log.
- Heartbeat replies arrive on the protocol's reserved heartbeat topic, which
  never has a channel, so they fall out as ordinary unknown-topic drops.
- Binary frames are ignored.
- A protocol close or error event *for this topic* becomes
  `Error(ChannelClosed)`, and terminates that channel only.

Everything else — including non-heartbeat replies nobody is waiting on — is
returned as an `Incoming` record.

## Refs and replies

Refs are minted **inside** the socket actor, in the same message handler that
sends the frame carrying them, so ref order and send order cannot diverge.

`push_and_await_reply` correlates a reply back to its push, so concurrent
pushes from different processes each get their own answer. Frames that arrive
while you are waiting are not dropped — they queue up for `receive` as usual.
That is the whole reason the socket keeps a pending-reply table.

A push reply carrying a non-ok status is an ordinary `Ok` result: interpreting
it is the caller's business. Only a *join* reply's status is turned into an
error, because a rejected join means there is no channel.

## Closing cleanly

`socket.close` closes the transport and stops the actor, taking the heartbeat
and every channel with it. Callers blocked on a reply are failed with
`ChannelClosed` rather than left to time out.

A deliberate close never reconnects. See [Reconnect](/guides/reconnect/).

## Related

- [Choosing your model](/guides/choosing-your-model/) — blocking `receive`
  versus the events subject.
- [One socket, many topics](/guides/multi-topic/) — sharing a connection.
- [Codecs](/guides/codecs/) — how channel logic stays protocol-agnostic.
- [Error handling](/guides/error-handling/) — the errors these operations
  can return.
