---
title: Phoenix and Beryl
description: Use the bundled aquamarine/phoenix codec to connect to Phoenix Channels and Beryl servers.
---

The `aquamarine/phoenix` module ships a ready-made
[`Codec`](/guides/codecs/) for the Phoenix Channels wire protocol. The
same codec works against any server that speaks that protocol — most
importantly, [Beryl](https://github.com/tylerbutler/beryl), which is a
Gleam-native Phoenix-compatible channel server.

## Wire it up

```gleam
import aquamarine
import aquamarine/phoenix
import aquamarine/transport
import gleam/json

let assert Ok(channel) =
  aquamarine.connect(
    scheme: transport.Ws,
    host: "localhost",
    port: 4000,
    path: "/socket/websocket",
    topic: "room:lobby",
    payload: json.object([]),
    codec: phoenix.codec(),
  )
```

That is the entire integration. From here, use
[`push`](/guides/channels/), [`receive`](/guides/channels/), and
[`close`](/guides/channels/) exactly as documented in the channel
lifecycle guide.

## What the codec speaks

Under the hood the codec delegates to [Roost](https://github.com/tylerbutler/roost),
which encodes and decodes the canonical Phoenix Channels v2 list format:

```
[join_ref, ref, topic, event, payload]
```

Aquamarine sees only the normalised `Incoming` record produced by Roost,
so you do not need to handle the list-positional encoding yourself.

The event-name constants used to drive the channel runtime
(`join_event`, `reply_event`, `close_event`, `error_event`,
`heartbeat_topic`) all come from Roost and match the Phoenix JS client's
behaviour.

## Topics and payloads

Topics follow the usual Phoenix conventions — `"room:lobby"`,
`"user:42"`, and so on. The `payload` argument to `connect` is whatever
JSON your server's `join/3` callback expects.

To push a message, use any event name your server understands:

```gleam
aquamarine.push(
  channel,
  "new_msg",
  json.object([#("body", json.string("hello"))]),
)
```

## Heartbeats

The bundled codec wires up Phoenix's heartbeat format (event
`"heartbeat"` on the `"phoenix"` topic). Aquamarine fires one every
30 seconds by default — the same cadence as the Phoenix JS client — and
the replies come back on the reserved `"phoenix"` topic, which never has a
channel, so they are dropped before they could reach any `receive`.

## Working with Beryl

Beryl is the server-side counterpart to Aquamarine in the same
ecosystem. If your Beryl server is bound to `localhost:4000` with the
default socket path, the snippet above connects to it without any
further configuration. See [Beryl ecosystem](/reference/ecosystem/) for
how the packages fit together.
