---
title: API overview
description: The public Aquamarine API, with pointers to the generated HexDocs.
---

Aquamarine's public surface is deliberately small. The top-level
[`aquamarine`](https://hexdocs.pm/aquamarine/aquamarine.html) module
re-exports the channel runtime API; everything else is internal.

For the full type signatures, browse the generated documentation on
[HexDocs](https://hexdocs.pm/aquamarine/). The summaries below are meant
to be a quick map.

## `config`

```gleam
pub fn config(
  host host: String,
  port port: Int,
  path path: String,
  topic topic: String,
  payload payload: json.Json,
  codec codec: Codec,
) -> Config
```

Builds the connection settings for a channel.

## `handlers`

```gleam
pub fn handlers(
  on_joined on_joined: fn(state, Dynamic) -> Next(state),
  on_message on_message: fn(state, Incoming) -> Next(state),
  on_error on_error: fn(state, AquamarineError) -> Next(state),
  on_closed on_closed: fn(state) -> Next(state),
) -> Handlers(state)
```

Builds the callback set that runs inside the channel actor. Use
`aquamarine.continue(state)` to keep the actor running and
`aquamarine.stop(state)` to end it.

## `connect`

```gleam
pub fn connect(
  config: Config,
  handlers: Handlers(state),
  initial_state: state,
) -> Result(Channel(state), AquamarineError)
```

Open a WebSocket, join `topic` with `payload`, wait for the join reply,
start the heartbeat, and hand control to the callbacks.

## `push`

```gleam
pub fn push(
  channel: Channel(state),
  event: String,
  payload: json.Json,
) -> Result(Nil, AquamarineError)
```

Encode `event` and `payload` with a fresh ref and hand the frame to the
transport. Does **not** wait for a reply.

## `close`

```gleam
pub fn close(channel: Channel(state)) -> Result(Nil, AquamarineError)
```

Stop the heartbeat and ref actors, then close the transport.

## `continue` and `stop`

The callback helpers return the next actor action:

- `continue(state)` keeps the channel actor running with the updated
  state.
- `stop(state)` ends the actor loop and closes the channel cleanly.

## Types you'll see

- [`Channel`](/guides/channels/) — opaque handle returned by `connect`.
- [`Config`](/guides/channels/) — connection settings built by `config`.
- [`Handlers`](/guides/channels/) — callback set built by `handlers`.
- [`Codec`](/guides/codecs/) — supplied to `config`; the bundled
  `aquamarine/phoenix.codec()` covers Phoenix Channels and Beryl.
- [`Incoming`](/guides/codecs/) — record delivered to `on_message`.
- [`AquamarineError`](/guides/error-handling/) — the unified error type
  used by all public operations.
