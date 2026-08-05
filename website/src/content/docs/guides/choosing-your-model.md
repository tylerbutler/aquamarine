---
title: Choosing your model
description: The blocking receive path and the subject path — which one you want, and why both exist.
---

Aquamarine gives you two ways to consume channel events. They are the same
mechanism underneath, and neither is a fallback for the other.

| You are writing | Use |
| --- | --- |
| A script, a CLI, a one-shot task | `channel.receive` |
| An actor, a GenServer-shaped process, anything already in a supervision tree | `channel.events` and your own selector |

The socket rewrite moved the WebSocket into an OTP actor, but **the blocking
API survived on purpose**. If you just want to talk to a channel, you do not
have to write an actor.

## The blocking path

`receive` blocks the calling process until the next frame for this channel's
topic arrives, or the timeout elapses.

```gleam
import aquamarine
import aquamarine/phoenix
import aquamarine/transport
import gleam/io
import gleam/json

pub fn main() {
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

  aquamarine.push(channel, "ping", json.object([]))
  listen(channel)

  let _ = aquamarine.close(channel)
  Nil
}

fn listen(channel) -> Nil {
  case aquamarine.receive(channel, 5000) {
    Ok(incoming) -> {
      io.println(incoming.event)
      listen(channel)
    }
    Error(error) -> {
      io.debug(error)
      Nil
    }
  }
}
```

That is the whole program. No actor, no selector, no supervision tree.

## The subject path

`channel.events` hands you the `Subject` that frames are delivered on, so you
can select on it alongside your own messages. This is what you want when the
channel is one input among several.

```gleam
import aquamarine/channel
import aquamarine/socket
import gleam/erlang/process
import gleam/io
import gleam/json
import gleam/otp/actor

type Message {
  FromChannel(socket.Event)
  Tick
  Shutdown
}

pub fn start(ch: channel.Channel, ticks: process.Subject(Nil)) {
  actor.new_with_initialiser(1000, fn(self) {
    let selector =
      process.new_selector()
      |> process.select(self)
      |> process.select_map(channel.events(ch), FromChannel)
      |> process.select_map(ticks, fn(_) { Tick })

    actor.initialised(ch)
    |> actor.selecting(selector)
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle)
  |> actor.start
}

fn handle(ch, message) {
  case message {
    FromChannel(Ok(incoming)) -> {
      io.println(incoming.event)
      actor.continue(ch)
    }
    FromChannel(Error(_reason)) -> actor.stop()
    Tick -> {
      channel.push(ch, "ping", json.object([]))
      actor.continue(ch)
    }
    Shutdown -> {
      let _ = channel.close(ch)
      actor.stop()
    }
  }
}
```

`socket.Event` is `Result(Incoming, AquamarineError)` — errors arrive in-band
on the same subject, because from a caller's point of view "the server closed
this topic" is just another thing that happened on it.

## The rule that binds both

**Only the process that called `connect` or `join` may consume events.** A
Gleam `Subject` can only be received from by the process that created it, and
that is the process that created it. This is not a policy — it is how
subjects work.

Everything else — `push`, `push_and_await_reply`, `leave`, `close`,
`socket.watch` — is safe from any process, because each is a message to the
socket actor.

So if you want an actor to own the channel, `join` from inside that actor's
initialiser. If you want a supervisor tree to own the *connection* but a
worker to own a *topic*, put the socket in the tree (see
[Supervision](/guides/supervision/)) and let the worker `channel.join` on it.
