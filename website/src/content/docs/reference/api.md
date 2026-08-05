---
title: API overview
description: The public surface — sockets, channels, and the configuration around them.
---

Aquamarine's surface is small and splits in two: `aquamarine/socket` owns a
connection, `aquamarine/channel` owns a topic on it. The top-level
[`aquamarine`](https://github.com/tylerbutler/aquamarine/blob/main/src/aquamarine.gleam)
module re-exports the single-topic path for callers who want one call.

For full type signatures, read the
[source on GitHub](https://github.com/tylerbutler/aquamarine/tree/main/src).
Aquamarine isn't published to Hex yet (pre-1.0). The summaries below are a
quick map.

## `aquamarine/socket`

```gleam
pub fn connect(
  scheme scheme: transport.Scheme,
  host host: String,
  port port: Int,
  path path: String,
  codec codec: Codec,
) -> Result(Socket, AquamarineError)
```

Open a connection. It carries no topics until something joins one. `scheme`
is `transport.Ws` or `transport.Wss`.

```gleam
pub fn config(scheme:, host:, port:, path:, codec:) -> Config
pub fn with_heartbeat_ms(config: Config, ms: Int) -> Config
pub fn with_backoff(config: Config, backoff: Backoff) -> Config
pub fn start(config: Config) -> Result(Socket, AquamarineError)
```

The same, with the heartbeat interval and
[reconnect schedule](/guides/reconnect/) under your control.

```gleam
pub fn close(socket: Socket) -> Result(Nil, AquamarineError)
```

Close the connection and stop the actor, taking every channel with it.

```gleam
pub fn watch(socket: Socket, watcher: Subject(Status)) -> Nil
pub fn unwatch(socket: Socket, watcher: Subject(Status)) -> Nil
```

Subscribe to connection lifecycle [`Status`](/guides/reconnect/#watching-it-happen)
events.

```gleam
pub fn new_name(prefix prefix: String) -> Name
pub fn named(name: Name) -> Socket
pub fn supervised(config: Config, name: Name) -> ChildSpecification(Socket)
```

[Supervision](/guides/supervision/) and named sockets.

## `aquamarine/channel`

```gleam
pub fn join(
  socket socket: Socket,
  topic topic: String,
  payload payload: json.Json,
  timeout timeout: Int,
) -> Result(Channel, AquamarineError)
```

Join a topic on an existing socket and block for the reply. The channel does
not own the socket.

```gleam
pub fn connect(
  scheme scheme: transport.Scheme,
  host host: String,
  port port: Int,
  path path: String,
  topic topic: String,
  payload payload: json.Json,
  codec codec: Codec,
) -> Result(Channel, AquamarineError)
```

Connection plus join in one call, for the single-topic case. The channel
**owns its socket**.

```gleam
pub fn push(channel: Channel, event: String, payload: json.Json) -> Nil
```

Encode `event` and `payload` with a fresh ref and hand the frame to the
socket actor. Fire-and-forget: it does not wait for a reply and cannot report
a delivery failure.

```gleam
pub fn push_and_await_reply(
  channel: Channel,
  event: String,
  payload: json.Json,
  timeout: Int,
) -> Result(Incoming, AquamarineError)
```

The same, but block for the reply carrying that ref. Correlated, so
concurrent pushes each get their own.

```gleam
pub fn receive(channel: Channel, timeout: Int) -> Result(Incoming, AquamarineError)
```

Block until the next frame for this topic arrives. Only the process that
called `connect` or `join` may call this — see
[process ownership](/guides/channels/#process-ownership).

```gleam
pub fn events(channel: Channel) -> Subject(socket.Event)
```

The subject frames are delivered on, for callers who want to select on it
alongside their own messages. See
[Choosing your model](/guides/choosing-your-model/).

```gleam
pub fn leave(channel: Channel) -> Result(Nil, AquamarineError)
pub fn close(channel: Channel) -> Result(Nil, AquamarineError)
```

`leave` is always leave-only. `close` also closes the connection **if this
channel owns it** — see
[who closes the connection](/guides/multi-topic/#who-closes-the-connection).

```gleam
pub fn join_reply(channel: Channel) -> Incoming
pub fn topic(channel: Channel) -> String
pub fn socket(channel: Channel) -> Socket
```

Accessors. `join_reply` is what the server actually answered the join with.

## `aquamarine`

The facade re-exports the single-topic path: `connect`, `push`,
`push_and_await_reply`, `receive`, `join_reply`, `leave`, and `close`.
Multi-topic callers use `aquamarine/socket` and `aquamarine/channel`
directly.

## Types you'll see

- [`Socket`](/guides/multi-topic/) — opaque handle to a connection.
- [`Channel`](/guides/channels/) — opaque handle to a joined topic.
- [`Codec`](/guides/codecs/) — supplied to the socket; the bundled
  `aquamarine/phoenix.codec()` covers Phoenix Channels and Beryl.
- [`Incoming`](/guides/codecs/) — record returned from `receive`.
- [`Status`](/guides/reconnect/) — connection lifecycle events.
- [`Backoff`](/guides/reconnect/) — the reconnect schedule.
- [`AquamarineError`](/guides/error-handling/) — the unified error type.
