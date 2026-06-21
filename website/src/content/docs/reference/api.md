---
title: API overview
description: The four public functions Aquamarine exposes, with pointers to the source.
---

Aquamarine's public surface is deliberately tiny. The top-level
[`aquamarine`](https://github.com/tylerbutler/aquamarine/blob/main/src/aquamarine.gleam) module
re-exports four lifecycle functions from `aquamarine/channel`. Supporting
modules such as `aquamarine/codec`, `aquamarine/error`, and
`aquamarine/phoenix` expose the types and codec adapters those functions use.

For the full type signatures, read the
[source on GitHub](https://github.com/tylerbutler/aquamarine/tree/main/src).
Aquamarine isn't published to Hex yet (pre-1.0). The summaries below are
meant to be a quick map.

## `connect`

```gleam
pub fn connect(
  host host: String,
  port port: Int,
  path path: String,
  topic topic: String,
  payload payload: json.Json,
  codec codec: Codec,
) -> Result(Channel, AquamarineError)
```

Open a WebSocket, join `topic` with `payload`, wait for the join reply,
and start the heartbeat. See [Channel lifecycle](/guides/channels/#what-connect-actually-waits-for)
for the exact sequence and cleanup guarantees.

## `push`

```gleam
pub fn push(
  channel: Channel,
  event: String,
  payload: json.Json,
) -> Result(Nil, AquamarineError)
```

Encode `event` and `payload` with a fresh ref and hand the frame to the
transport. Does **not** wait for a reply.

## `receive`

```gleam
pub fn receive(channel: Channel) -> Result(Incoming, AquamarineError)
```

Block until the next application-level inbound frame arrives. Skips
binary frames and heartbeat replies, and translates protocol close/error
events into `Error(ChannelClosed)`. Only the process that called
`connect` should call this — see
[process ownership](/guides/channels/#process-ownership).

## `close`

```gleam
pub fn close(channel: Channel) -> Result(Nil, AquamarineError)
```

Stop the heartbeat and ref actors, then close the transport.

## Types you'll see

- [`Channel`](/guides/channels/) — opaque handle returned by `connect`.
- [`Codec`](/guides/codecs/) — supplied to `connect`; the bundled
  `aquamarine/phoenix.codec()` covers Phoenix Channels and Beryl.
- [`Incoming`](/guides/codecs/) — record returned from `receive`.
- [`AquamarineError`](/guides/error-handling/) — the unified error type
  used by all four operations.
