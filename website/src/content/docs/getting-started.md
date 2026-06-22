---
title: Getting started
description: Install Aquamarine, open a channel, handle callbacks, push messages, and close cleanly.
---

This guide walks through opening a channel against a Phoenix-compatible
WebSocket endpoint (Phoenix itself or [Beryl](https://github.com/tylerbutler/beryl)),
pushing a message, handling callbacks, and shutting down.

## Install

Add Aquamarine to your Gleam project:

```sh
gleam add aquamarine
```

Aquamarine targets the Erlang runtime. It uses OTP actors for its ref
counter and heartbeat scheduling, and [Stratus](https://github.com/rawhat/stratus)
for the WebSocket actor and transport lifecycle.

## Connect

`aquamarine.connect` opens the WebSocket, joins the given topic, waits for
the matching `phx_reply`, schedules the first heartbeat tick after join,
and wires in your callbacks. It returns a `Channel` handle that you keep
for the rest of the session.

```gleam
import aquamarine
import aquamarine/codec.{type Incoming}
import aquamarine/error.{type AquamarineError}
import aquamarine/phoenix
import gleam/json

type State {
  State(messages: Int)
}

pub fn main() {
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

  // ... use the channel ...

  let _ = aquamarine.close(channel)
}
```

The `payload` argument is the join payload — it is what the server's
`join/3` callback sees.

## Handle callbacks

Aquamarine hands inbound events to your callbacks instead of exposing a
separate loop.

- `on_joined` runs after the join reply arrives.
- `on_message` runs for application messages.
- `on_error` runs when the runtime sees a transport or decode failure, or a
  protocol error event.
- `on_closed` runs when the peer or protocol closes the channel. It does not
  run for your own `close(channel)` call.

Return `aquamarine.continue(state)` to keep the actor running, or
`aquamarine.stop()` to end it. For terminal callbacks, such as `on_closed` and
protocol/transport terminal `on_error`, the channel has already stopped and the
return value is ignored.

## Push an event

`push` assigns a ref automatically and hands the encoded frame to the
transport. It returns once the frame is enqueued; it does **not** wait
for a reply.

```gleam
let _ =
  aquamarine.push(
    channel,
    "new_msg",
    json.object([#("body", json.string("hello"))]),
  )
```

## Close

`close` stops heartbeat timer state and the ref counter, then closes the
underlying socket.

```gleam
let _ = aquamarine.close(channel)
```

## Next steps

- [Channel lifecycle](/guides/channels/) — how `connect`, `push`,
  callbacks, and `close` fit together.
- [Phoenix and Beryl](/guides/phoenix/) — using the bundled codec
  against a real server.
- [Error handling](/guides/error-handling/) — the `AquamarineError`
  variants you should expect to handle.
