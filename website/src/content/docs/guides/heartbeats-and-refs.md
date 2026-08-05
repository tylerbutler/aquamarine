---
title: Heartbeats and refs
description: How the socket keeps the connection alive and assigns refs, and what callers do not need to manage.
---

Both of these used to be separate OTP actors. They are now plain state inside
the socket actor, which is the process that was always going to need them.
You should rarely have to think about either — this page is here so you know
what is happening if you ever do.

## Refs

Phoenix-style channel protocols correlate requests and replies by an opaque
string ref. The socket mints them from a counter in its own state:

- The first ref is `"1"`, then `"2"`, and so on, as strings.
- `join` mints one to use as the `join_ref`.
- Every `push` mints a new one before encoding the frame.
- The heartbeat mints a fresh one on every tick.

The ref is minted **in the same message handler that sends the frame carrying
it**. Under the old design a ref was obtained and the frame sent in two steps
from two different processes, so ref order and send order could diverge. Now
they cannot.

Refs keep counting up across a reconnect rather than resetting. If they
restarted at `"1"`, a stale in-flight reply from the dropped connection could
correlate against a fresh ref on the new one.

## Join refs and rejoins

Each joined topic carries a join ref, and the socket stamps it onto that
topic's outbound frames. You never pass one.

That is what makes a rejoin invisible: after a reconnect the topic is rejoined
under a *new* join ref, and because the socket owns it rather than your
`Channel` handle, nothing you hold goes stale.

## Heartbeats

The heartbeat is a timed self-message inside the socket actor. On each tick it
mints a ref, calls `codec.encode_heartbeat(ref)`, sends the frame, and
reschedules.

The default interval is **30 seconds**, matching the Phoenix JS client.
Override it with `socket.with_heartbeat_ms` on the config.

It runs for the life of the connection regardless of how many channels are
joined, including zero — the heartbeat lives on the socket, not the channel.
A socket that has lost its connection stops beating, and starts again once it
reconnects.

Heartbeat replies come back on the protocol's reserved heartbeat topic, which
never has a channel, so they are dropped as ordinary unknown-topic frames.
There is no special case for them, and they never surface to `receive`.

## What `close` does for you

Closing the socket cancels the pending heartbeat tick before stopping, so no
heartbeat frame outlives a close. There is no race in which a tick beats a
teardown.

## Configuration

```gleam
import aquamarine/socket

let config =
  socket.config(scheme:, host:, port:, path:, codec:)
  |> socket.with_heartbeat_ms(10_000)
```

## Related

- [Reconnect](/guides/reconnect/) — what refs and heartbeats do across a
  dropped connection.
- [Error handling](/guides/error-handling/) — the full error taxonomy.
