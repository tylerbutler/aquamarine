---
title: One socket, many topics
description: Sharing a single connection across several channels, and who owns closing it.
---

Phoenix multiplexes many topics over a single WebSocket, and so does
Aquamarine. Open a socket once, join as many topics as you need, and they
share one connection and one heartbeat.

## Two ways in

```gleam
// One call, one topic. The channel owns its socket.
channel.connect(scheme:, host:, port:, path:, topic:, payload:, codec:)

// A connection first, then topics on it. The channels do not own the socket.
socket.connect(scheme:, host:, port:, path:, codec:)
channel.join(socket:, topic:, payload:, timeout:)
```

`connect` is the convenience for the single-topic case. Anything more, and
you want the socket.

```gleam
import aquamarine/channel
import aquamarine/phoenix
import aquamarine/socket
import aquamarine/transport
import gleam/json

let assert Ok(sock) =
  socket.connect(
    scheme: transport.Ws,
    host: "localhost",
    port: 4000,
    path: "/socket/websocket",
    codec: phoenix.codec(),
  )

let assert Ok(lobby) = channel.join(sock, "room:lobby", json.object([]), 5000)
let assert Ok(alerts) = channel.join(sock, "user:alerts", json.object([]), 5000)
```

One connection, one heartbeat, two channels. Each channel receives only its
own topic's frames.

## Who closes the connection

This is the part worth reading twice.

| Channel came from | `leave` | `close` |
| --- | --- | --- |
| `channel.connect` | Leaves the topic | Leaves the topic **and closes the connection** |
| `channel.join` | Leaves the topic | Leaves the topic |

A channel from `connect` owns its socket, because `connect` opened that
socket on your behalf and nothing else is going to close it. A channel from
`join` does not, because you opened the socket and other channels may still
be using it.

`leave` always means leave, whichever way the channel arrived. Use it when
you want to be explicit.

To close a connection you opened yourself, close the socket:

```gleam
let assert Ok(Nil) = socket.close(sock)
```

That takes every channel on it with it.

## The socket does not close itself

When the last channel leaves, the connection stays open. Refcount-driven
teardown would kill the connection during any transient zero-channel window
— a page that leaves one topic before joining the next would drop and re-open
its socket for no reason. Closing is `socket.close`, explicitly.

The heartbeat runs for the life of the socket regardless of how many channels
are joined, including zero. This matches the Phoenix JS client: the heartbeat
lives on the socket, not the channel.

## Rules around joining

- **Joining a topic you have already joined is an error**,
  `AlreadyJoined(topic)`. Silently replacing the routing entry would orphan
  the first channel's subject with no error raised anywhere — the worst
  available outcome. Re-joining after a `leave` is fine.
- **Joining the protocol's heartbeat topic is rejected**,
  `ReservedTopic(topic)`. That topic is the socket's own.

## Failures are scoped to their topic

A `phx_close` or `phx_error` for one topic terminates *that* channel only.
Its `receive` returns `Error(ChannelClosed)`; the socket and every other
channel carry on.

Frames for a topic nobody joined are dropped with a debug log, never a crash.
Heartbeat replies arrive on the reserved heartbeat topic, which never has a
channel, so they fall out that way — which is why they never reach your
`receive`.

## Related

- [Supervision](/guides/supervision/) — putting the socket in your tree.
- [Reconnect](/guides/reconnect/) — every joined topic is rejoined.
