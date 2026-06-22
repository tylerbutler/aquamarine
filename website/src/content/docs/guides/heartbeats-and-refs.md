---
title: Heartbeats and refs
description: How Aquamarine keeps the channel alive and assigns refs, and what callers do not need to manage.
---

Two small OTP actors live behind every `Channel`: a **ref counter** that
hands out monotonic refs for outbound frames, and a **heartbeat** loop
driven by the channel actor that periodically sends a heartbeat frame
using one of those refs. Both are started by `connect` and stopped by
`close`. You should rarely need to think about them — this page is here
so you know what's happening if you ever do.

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

`close` stops the heartbeat actor first, then the ref counter, then
closes the transport. There is no race in which a heartbeat tick races a
close — by the time the transport is touched, the heartbeat is no longer
ticking.

The heartbeat actor's `Heartbeat` and `Message` types and the ref
counter's `Counter` and `Message` types are all opaque. The public API
gives you no way (and no reason) to send messages directly to either
actor.

## When things go wrong

- If the ref counter fails to start, `connect` returns
  `Error(InternalError(...))` and tears down the socket.
- There is no separate heartbeat startup failure anymore; the heartbeat is
  scheduled by the channel actor after join.
- If a heartbeat send or ref lookup fails mid-session, the failure is
  delivered to `on_error`, and the `Next` value you return decides whether
  the channel continues or stops.

See [Error handling](/guides/error-handling/) for the full error taxonomy.
