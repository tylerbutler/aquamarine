---
title: Getting started
description: Install Aquamarine, open a channel, push and receive messages, and close cleanly.
---

This guide walks through opening a channel against a Phoenix-compatible
WebSocket endpoint (Phoenix itself or [Beryl](https://github.com/tylerbutler/beryl)),
pushing a message, receiving a reply, and shutting down.

## Install

Aquamarine is pre-1.0 and is not published to Hex yet. Until it is, add it as
a Git dependency in your `gleam.toml`:

```toml
[dependencies]
aquamarine = { git = "https://github.com/tylerbutler/aquamarine.git", ref = "main" }
```

Aquamarine targets the Erlang runtime. The socket lives in an OTP actor, and
the WebSocket itself is [Collie](https://hex.pm/packages/collie).

## Connect

`aquamarine.connect` opens the WebSocket, joins the given topic, waits for
the join reply, and starts the background heartbeat. It returns a `Channel`
handle that you keep for the rest of the session.

```gleam
import aquamarine
import aquamarine/phoenix
import aquamarine/transport
import gleam/io
import gleam/json

pub fn main() {
  case aquamarine.connect(
    scheme: transport.Ws,
    host: "localhost",
    port: 4000,
    path: "/socket/websocket",
    topic: "room:lobby",
    payload: json.object([]),
    codec: phoenix.codec(),
  ) {
    Ok(channel) -> {
      // ... use the channel ...
      case aquamarine.close(channel) {
        Ok(Nil) -> Nil
        Error(error) -> {
          io.debug(error)
          Nil
        }
      }
    }

    Error(error) -> {
      io.debug(error)
      Nil
    }
  }
}
```

Use `transport.Wss` for TLS. It applies system CA certificates and HTTPS
hostname verification, with no way to turn either off.

The `payload` argument is the join payload — it is what the server's
`join/3` callback sees. What the server *answered* with is available
afterwards from `aquamarine.join_reply(channel)`.

This is the one-call path, and it is the right one when you want a single
topic. The channel it returns **owns its socket**, so `close` on it closes
the connection. For several topics on one connection, see
[One socket, many topics](/guides/multi-topic/).

## Push an event

`push` assigns a ref automatically and hands the frame to the socket actor.
It is fire-and-forget: it returns immediately and does not wait for a reply.

```gleam
aquamarine.push(
  channel,
  "new_msg",
  json.object([#("body", json.string("hello"))]),
)
```

When you want the server's answer to a specific push, use
`push_and_await_reply`, which correlates the reply by ref:

```gleam
case
  aquamarine.push_and_await_reply(
    channel,
    "new_msg",
    json.object([#("body", json.string("hello"))]),
    5000,
  )
{
  Ok(reply) -> handle(reply)
  Error(error) -> io.debug(error)
}
```

Frames that arrive while you are waiting are not dropped — they queue up for
`receive` as usual.

## Receive frames

`receive` blocks until the next frame for this channel's topic arrives, or
the timeout elapses. Only this topic's frames arrive here; heartbeat replies
and binary frames never do.

```gleam
case aquamarine.receive(channel, 5000) {
  Ok(incoming) -> {
    // incoming.event, incoming.topic, incoming.payload, ...
    Nil
  }
  Error(error) -> {
    io.debug(error)
    Nil
  }
}
```

Only the process that called `connect` should call `receive` — see
[Channel lifecycle](/guides/channels/) for the full ownership rules, and
[Choosing your model](/guides/choosing-your-model/) if you would rather
select on the subject alongside your own messages.

## Close

`close` closes the connection and stops the socket actor, taking the
heartbeat with it.

```gleam
case aquamarine.close(channel) {
  Ok(Nil) -> Nil
  Error(error) -> {
    io.debug(error)
    Nil
  }
}
```

Use `aquamarine.leave(channel)` when you mean *leave the topic* and nothing
more.

## Next steps

- [Choosing your model](/guides/choosing-your-model/) — blocking `receive`
  or the events subject, and which is which.
- [Channel lifecycle](/guides/channels/) — how the operations fit together,
  including process ownership.
- [One socket, many topics](/guides/multi-topic/) — sharing one connection.
- [Reconnect](/guides/reconnect/) — what happens when the connection drops.
- [Supervision](/guides/supervision/) — putting a socket in your tree.
- [Error handling](/guides/error-handling/) — the `AquamarineError`
  variants you should expect to handle.
