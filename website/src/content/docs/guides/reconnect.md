---
title: Reconnect
description: What happens when the connection drops — backoff, rejoin, and what your application still has to do.
---

An unexpected disconnect does not end the socket. It moves to a reconnecting
state, retries on a capped exponential backoff, and on success rejoins every
topic that was joined before the drop.

Your `Channel` handles stay valid throughout. The actor is the same process,
so their events subjects still work — a reconnect is meant to be invisible to
a topic that is otherwise fine.

A deliberate `socket.close`, and a `channel.leave`, never trigger any of
this.

## The schedule

The default is 1s, 2s, 4s, 8s, then 10s for as long as it takes, each with up
to 20% jitter subtracted so a fleet of clients does not reconnect in lockstep.
It retries forever, which is the usual choice for a client.

```gleam
import aquamarine/backoff
import aquamarine/socket
import aquamarine/transport

let config =
  socket.config(
    scheme: transport.Ws,
    host: "localhost",
    port: 4000,
    path: "/socket/websocket",
    codec: phoenix.codec(),
  )
  |> socket.with_backoff(
    backoff.default()
    |> backoff.with_initial_ms(250)
    |> backoff.with_max_ms(30_000)
    |> backoff.with_max_attempts(20),
  )

let assert Ok(sock) = socket.start(config)
```

`backoff.delay_ms(schedule, attempt)` is a pure function of the attempt
number, and `backoff.with_jitter` replaces the jitter function — so you can
assert the exact delays your application will use without waiting for them.

When a capped schedule runs out of attempts, every channel gets
`Error(ReconnectFailed(attempts))` and the socket stops trying.

## Watching it happen

```gleam
import aquamarine/socket
import gleam/erlang/process

let status = process.new_subject()
socket.watch(sock, status)
```

`Status` events arrive on that subject:

| Event | Meaning |
| --- | --- |
| `Connected` | Connected, or reconnected. Rejoins have not been attempted yet. |
| `Disconnected(reason)` | The connection dropped unexpectedly. A reconnect follows. |
| `Reconnecting(attempt, delay_ms)` | About to retry, after `delay_ms`. |
| `Rejoined(topic)` | That topic was rejoined successfully. |
| `RejoinFailed(topic, reason)` | The server refused that rejoin. That channel is finished. |
| `GaveUp(attempts)` | Hit the attempt limit and stopped. |

These deliberately do **not** go into the channel event stream. Keeping them
separate means `channel.receive` still means exactly "the next thing that
happened on my topic". The consequence is worth knowing: from `receive`, a
quiet channel and a reconnecting socket look identical — both time out.
`watch` is how you tell them apart.

## What happens to traffic in between

- **Pushes issued while disconnected do not go out.** Nothing is buffered.
  Buffering would create delivery expectations this library cannot honour —
  a frame accepted into a buffer looks delivered, and it is not.
  `push_and_await_reply` returns `Error(Disconnected)`. Plain `push` is
  fire-and-forget, so it has no way to tell you; it is dropped with a debug
  log. If you need to know, watch the status stream.
- **`join` while disconnected returns `Error(Disconnected)`** rather than
  queueing a join for a connection that may never come back.
- **Pending replies are failed at the disconnect**, with `ChannelClosed`. A
  caller blocked in `push_and_await_reply` never outlives the connection it
  was waiting on, and its reply is never re-correlated against the new one.
- **Refs keep counting up** across a reconnect rather than resetting, so a
  stale in-flight reply from the old connection cannot correlate against a
  fresh ref on the new one.

## When a rejoin is refused

An expired token, a topic that no longer exists — the server can turn a
rejoin down. That channel is finished: it gets
`Error(RejoinRejected(topic, reason))` on its own events, and the status
stream gets `RejoinFailed`. The socket and its other channels carry on.

## What your application still has to do

Aquamarine restores the *connection* and the *topics*. It cannot restore your
application's assumptions about what happened while you were away:

- **Re-fetch anything you were tracking incrementally.** Broadcasts sent
  during the gap are gone; the server did not queue them for you.
- **Re-send anything a push was supposed to accomplish.** A push issued while
  disconnected did not happen, and a pending reply failed with
  `ChannelClosed`. Neither is retried for you.
- **Re-establish server-side state that lives on the connection**, such as a
  presence entry, if your server ties it to the socket rather than the join.

Watching for `Rejoined` is the natural place to do all three.

## Reconnect is not supervisor restart

They are different mechanisms with different consequences, and it matters
which one you are relying on. See
[Supervision](/guides/supervision/#restart-is-not-reconnect).
