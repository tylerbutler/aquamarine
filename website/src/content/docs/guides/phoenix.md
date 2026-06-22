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
import aquamarine/codec.{type Incoming}
import aquamarine/phoenix
import aquamarine/error.{type AquamarineError}
import gleam/json

type State {
  State(messages: Int)
}

let handlers =
  aquamarine.handlers(
    on_joined: fn(state, _reply_payload) {
      aquamarine.continue(state)
    },
    on_message: fn(state, _incoming: Incoming) {
      aquamarine.continue(State(messages: state.messages + 1))
    },
    on_error: fn(state, _err: AquamarineError) {
      aquamarine.continue(state)
    },
    on_closed: fn(state) {
      aquamarine.continue(state)
    },
  )

let assert Ok(channel) =
  aquamarine.connect(
    aquamarine.config(
      host: "localhost",
      port: 4000,
      path: "/socket/websocket",
      topic: "room:lobby",
      payload: json.object([]),
      codec: phoenix.codec(),
    ),
    handlers,
    State(messages: 0),
  )
```

That is the entire integration. Inbound messages arrive in your callback
functions. From there, use [`push`](/guides/channels/) and
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
let _ =
  aquamarine.push(
    channel,
    "new_msg",
    json.object([#("body", json.string("hello"))]),
  )
```

## Heartbeats

The bundled codec wires up Phoenix's heartbeat format (event
`"heartbeat"` on the `"phoenix"` topic). Aquamarine schedules one every
30 seconds by default — the same cadence as the Phoenix JS client — and
the channel actor swallows the matching replies before they reach your
callbacks.

## Working with Beryl

Beryl is the server-side counterpart to Aquamarine in the same
ecosystem. If your Beryl server is bound to `localhost:4000` with the
default socket path, the snippet above connects to it without any
further configuration. See [Beryl ecosystem](/reference/ecosystem/) for
how the packages fit together.
