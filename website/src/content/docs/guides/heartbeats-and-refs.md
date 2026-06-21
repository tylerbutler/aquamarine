---
title: Heartbeats and refs
description: How Aquamarine keeps the channel alive and assigns refs, and what callers do not need to manage.
---

Two small OTP actors live behind every `Channel`: a **ref counter** that
hands out monotonic refs for outbound frames, and a **heartbeat** that
periodically sends a heartbeat frame using one of those refs. Both are
started by `connect` and stopped by `close`. You should rarely need to
think about them — this page is here so you know what's happening if you
ever do.

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

The heartbeat actor is started after the join reply succeeds. On each
tick it:

1. Asks the ref counter for the next ref.
2. Calls `codec.encode_heartbeat(ref)` to build the frame.
3. Sends the frame through the same socket as `push`.

The default interval is **30 seconds**, matching the Phoenix JS client.
If `send_fn` ever fails — typically because the socket is gone — the
heartbeat actor stops itself.

Heartbeat replies from the server are filtered out inside `receive`, so
they never surface as application-visible frames.

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
- If the heartbeat fails to start, `connect` returns
  `Error(InternalError(...))` and tears down both the counter and the socket.
- If the heartbeat fails to send mid-session, the actor stops silently;
  the next `push` or `receive` will surface the underlying transport
  error.

See [Error handling](/guides/error-handling/) for the full error taxonomy.
