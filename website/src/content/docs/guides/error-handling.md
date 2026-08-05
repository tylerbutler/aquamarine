---
title: Error handling
description: The AquamarineError variants you should expect, and what causes each one.
---

Every fallible Aquamarine operation returns `Result(_, AquamarineError)`.
This page lists the variants and the situations that produce them, so you can
write a single `case` that handles them all.

`push` is the exception: it is fire-and-forget and returns `Nil`. A failure
there takes the connection down and surfaces as a disconnect — see
[Reconnect](/guides/reconnect/).

## `AquamarineError` variants

```gleam
pub type AquamarineError {
  Transport(TransportError)
  JoinRejected(reason: String)
  ChannelClosed
  AlreadyJoined(topic: String)
  ReservedTopic(topic: String)
  Disconnected
  RejoinRejected(topic: String, reason: String)
  ReconnectFailed(attempts: Int)
  DecodeFailed(codec.DecodeError)
  ReplyTimeout
  InternalError(reason: String)
}
```

### `Transport(TransportError)`

Wraps a failure from the underlying WebSocket transport
([Collie](https://hex.pm/packages/collie)).

The transport names about thirty POSIX socket conditions. Rather than mirror
all of them, Aquamarine classifies the handful you can act on differently and
keeps the transport's own name as a string for the rest — so nobody branching
on "did the connection drop?" has to enumerate `Enopkg`.

| Variant | Typical cause |
| --- | --- |
| `Closed` | The connection is closed. Nothing to retry against. |
| `ClosedWith(code, reason)` | The WebSocket closed with a protocol close code. |
| `Timeout` | A socket operation exceeded its deadline. |
| `ConnectionRefused` | Nothing is listening on the other end. |
| `Unreachable(reason)` | The host or network could not be reached. |
| `ConnectionLost(reason)` | An established connection was dropped underneath us. |
| `ConnectFailed(reason)` | The connection could not be established: refused handshake, rejected upgrade, TLS failure. |
| `SocketError(reason)` | Any other socket-level failure, carrying the transport's own name for it. |

Connect-time classification is coarser than the rest: the handshake happens
inside the transport's own initialiser, so a refused connection and a rejected
upgrade both arrive as `ConnectFailed` with a message.

`Transport(Timeout)` is also what `receive` returns when nothing arrives
within its timeout. That is not a failure — a quiet channel looks exactly like
this.

### `JoinRejected(reason)`

The server saw your join and turned it down. The `reason` is the reply's
status string (e.g. `"unauthorized"`), or `"error"` if the payload could not
be interpreted further.

### `ChannelClosed`

The channel is no longer usable. Returned when:

- The server sent a protocol close or error event for this topic.
- The socket was closed deliberately while you held a channel on it.
- You were blocked on a reply and the connection went away underneath you.

### `AlreadyJoined(topic)`

This socket has already joined that topic. Silently replacing the routing
entry would orphan the first channel's subject with no error raised anywhere,
so joining twice is an error rather than a takeover. Re-joining after a
`leave` is fine.

### `ReservedTopic(topic)`

You tried to join the protocol's heartbeat topic. That one is the socket's
own.

### `Disconnected`

The socket lost its connection and is retrying. Nothing was sent.

Frames are deliberately not buffered while disconnected — a frame accepted
into a buffer looks delivered and is not. Returned by
`push_and_await_reply` and by `join`.

### `RejoinRejected(topic, reason)`

After a reconnect, the server refused to rejoin this topic — an expired
token, a topic that no longer exists. That channel is finished; the socket
and its other channels are not.

### `ReconnectFailed(attempts)`

Reconnect hit its configured attempt limit and stopped trying. Only reachable
if you set one; the default retries forever.

### `DecodeFailed(codec.DecodeError)`

An inbound frame arrived but the configured codec could not decode it. The
inner value is one of:

- `InvalidJson(reason)` — the text was not valid JSON.
- `InvalidFormat(reason)` — the JSON did not match the protocol's expected
  shape.

This usually means the server is speaking a different protocol from the codec
you configured. A frame that cannot be decoded has no topic to route by, so
it is reported to every joined channel and fails anyone blocked on a reply —
but the connection itself is left alone.

### `ReplyTimeout`

You waited for a reply matching an outbound ref and it did not arrive in
time. Returned by `push_and_await_reply` and by `join`.

The pending entry is dropped when this happens, so a caller that gives up
does not leak one; a reply that arrives afterwards falls through to the
topic's channel like any other unclaimed frame.

A codec that cannot correlate replies at all degrades to this rather than
hanging.

### `InternalError(reason)`

Aquamarine could not start the socket actor. Any resources started before the
failure are torn down first.

## A complete handler

```gleam
import aquamarine
import aquamarine/error.{
  AlreadyJoined, ChannelClosed, DecodeFailed, Disconnected, InternalError,
  JoinRejected, ReconnectFailed, RejoinRejected, ReplyTimeout, ReservedTopic,
  Transport,
}

case aquamarine.receive(channel, 5000) {
  Ok(incoming) -> handle(incoming)

  // Expected: a quiet channel, or a socket that is reconnecting.
  Error(Transport(error.Timeout)) -> keep_waiting()

  Error(ChannelClosed) -> rejoin()
  Error(RejoinRejected(topic, reason)) -> give_up_on(topic, reason)
  Error(ReconnectFailed(attempts)) -> alert(attempts)
  Error(Transport(t)) -> log_transport_error(t)
  Error(DecodeFailed(d)) -> log_decode_error(d)
  Error(JoinRejected(reason)) -> give_up(reason)
  Error(AlreadyJoined(topic)) -> log_bug(topic)
  Error(ReservedTopic(topic)) -> log_bug(topic)
  Error(Disconnected) -> keep_waiting()
  Error(ReplyTimeout) -> retry()
  Error(InternalError(reason)) -> log_internal_error(reason)
}
```

Most of those cannot actually come out of `receive` — the exhaustive match is
there so a `case` over `AquamarineError` anywhere in your application has a
home for each one.
