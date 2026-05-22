---
title: Getting started
description: Install Aquamarine, open a channel, push and receive messages, and close cleanly.
---

This guide walks through opening a channel against a Phoenix-compatible
WebSocket endpoint (Phoenix itself or [Beryl](https://github.com/tylerbutler/beryl)),
pushing a message, receiving a reply, and shutting down.

## Install

Add Aquamarine to your Gleam project:

```sh
gleam add aquamarine
```

Aquamarine targets the Erlang runtime — it relies on OTP actors for its
ref counter and heartbeat, and on [Gluegun](https://github.com/tylerbutler/gluegun)
for the underlying WebSocket transport.

## Connect

`aquamarine.connect` opens the WebSocket, joins the given topic, waits for
the matching `phx_reply`, and starts the background heartbeat. It returns
a `Channel` handle that you keep for the rest of the session.

```gleam
import aquamarine
import aquamarine/phoenix
import gleam/json

pub fn main() {
  let assert Ok(channel) =
    aquamarine.connect(
      host: "localhost",
      port: 4000,
      path: "/socket/websocket",
      topic: "room:lobby",
      payload: json.object([]),
      codec: phoenix.codec(),
    )

  // ... use the channel ...

  let _ = aquamarine.close(channel)
}
```

The `payload` argument is the join payload — it is what the server's
`join/3` callback sees.

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

## Receive frames

`receive` blocks until the next application-level frame arrives. It
skips heartbeat replies and binary frames so you only see real channel
activity.

```gleam
case aquamarine.receive(channel) {
  Ok(incoming) -> {
    // incoming.event, incoming.topic, incoming.payload, ...
    Nil
  }
  Error(_) -> Nil
}
```

Only the process that called `connect` should call `receive` — see
[Channel lifecycle](/guides/channels/) for the full ownership rules.

## Close

`close` stops the heartbeat and ref counter actors, then closes the
underlying socket.

```gleam
let _ = aquamarine.close(channel)
```

## Next steps

- [Channel lifecycle](/guides/channels/) — how `connect`, `push`,
  `receive`, and `close` fit together, including process ownership.
- [Phoenix and Beryl](/guides/phoenix/) — using the bundled codec
  against a real server.
- [Error handling](/guides/error-handling/) — the `AquamarineError`
  variants you should expect to handle.
