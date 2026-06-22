---
title: Heartbeats and refs
description: How Aquamarine keeps the channel alive and assigns refs, and what callers do not need to manage.
---

Every `Channel` owns a **ref counter** actor that hands out monotonic refs
for outbound frames. Heartbeats run as timer state inside the channel actor:
each tick asks the counter for a ref, encodes a heartbeat frame, and sends it
through the socket. `connect` starts this state, and `close` stops it. You
should rarely need to think about it — this page is here so you know what's
happening if you ever do.

## Refs

Phoenix-style channel protocols correlate requests and replies by an
opaque string ref. Aquamarine generates these with a tiny counter actor:

- The counter starts at `0`. The first `next` call returns `"1"`, the
  second returns `"2"`, and so on, as strings.
- `connect` pulls the first ref to use as the `join_ref`.
- Every `push` pulls a new ref before encoding the frame.
- The heartbeat pulls a fresh ref on every tick.

The `Counter` type is **opaque** — callers cannot construct one or read
its internal subject. That is intentional: it stops user code from
accidentally sharing a counter between channels or driving it
out-of-band.

## Heartbeats

The channel actor schedules the first heartbeat after the join reply
succeeds. On each tick it:

1. Asks the ref counter for the next ref.
2. Calls `codec.encode_heartbeat(ref)` to build the frame.
3. Sends the frame through the same socket as `push`.

The default interval is **30 seconds**, matching the Phoenix JS client.
If the heartbeat send or ref lookup fails — typically because the socket
is gone or the channel has already closed — the failure is reported to
`on_error`, and the returned `Next` value controls whether the channel
keeps running or stops.

Heartbeat replies from the server are filtered out before callbacks run,
so they never surface as application-visible frames.

## What `close` does for you

Heartbeats and close requests are serialized through the channel actor. An
already-queued heartbeat tick may run before a queued close request, but once
close is processed the runtime stops its ref and heartbeat state before the
actor exits.

The standalone heartbeat helper's `Heartbeat` and `Message` types and the
ref counter's `Counter` and `Message` types are all opaque. The public API
gives you no way (and no reason) to send messages directly to runtime
internals.

## When things go wrong

- If the ref counter fails to start, `connect` returns
  `Error(InternalError(...))` and tears down the socket.
- There is no separate heartbeat startup failure anymore; the heartbeat is
  scheduled by the channel actor after join.
- If a heartbeat send or ref lookup fails mid-session, the failure is
  delivered to `on_error`, and the `Next` value you return decides whether
  the channel continues or stops.

See [Error handling](/guides/error-handling/) for the full error taxonomy.
