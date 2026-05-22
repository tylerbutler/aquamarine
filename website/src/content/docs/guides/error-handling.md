---
title: Error handling
description: The AquamarineError variants you should expect, and what causes each one.
---

Every public Aquamarine operation returns
`Result(_, AquamarineError)`. This page lists the variants and the
situations that produce them, so you can write a single `case` that
handles them all.

## `AquamarineError` variants

```gleam
pub type AquamarineError {
  Transport(TransportError)
  JoinRejected(reason: String)
  ChannelClosed
  DecodeFailed(codec.DecodeError)
  ReplyTimeout
}
```

### `Transport(TransportError)`

Wraps a failure from the underlying WebSocket transport
([Gluegun](https://github.com/tylerbutler/gluegun)). Returned by
`connect`, `push`, `receive`, and `close` whenever the socket itself
misbehaves. The inner `TransportError` classifies the failure further:

| Variant                       | Typical cause                                              |
| ----------------------------- | ---------------------------------------------------------- |
| `Timeout`                     | A transport operation exceeded its deadline.               |
| `ConnectionDown(reason)`      | The underlying connection was lost.                        |
| `ConnectionError(reason)`     | A connection attempt failed.                               |
| `StreamError(reason)`         | The WebSocket stream errored.                              |
| `InvalidOptions(reason)`      | Bad transport configuration.                               |
| `InvalidMessage(reason)`      | The transport received something it could not classify.    |
| `ErlangError(reason)`         | An unexpected Erlang-level failure bubbled up.             |
| `DecodeError(reason)`         | The transport could not decode a low-level frame.          |

### `JoinRejected(reason)`

`connect` saw a `phx_reply` for the join, but its `status` was not
`"ok"`. The `reason` is the reply's status string (e.g. `"unauthorized"`),
or `"malformed reply"` if the payload could not be decoded.

### `ChannelClosed`

The channel is no longer usable. Returned by `receive` when:

- The server sent a protocol close or error event.
- The underlying socket closed.

Also returned by `push` if the ref counter actor has stopped (which
itself indicates the channel was torn down).

### `DecodeFailed(codec.DecodeError)`

An inbound frame was received but the configured codec could not decode
it. The inner value is one of:

- `InvalidJson(reason)` — the text was not valid JSON.
- `InvalidFormat(reason)` — the JSON did not match the protocol's
  expected shape.

This usually means the server is speaking a different protocol from the
codec you configured.

### `ReplyTimeout`

Returned by `connect` when an internal actor (ref counter or heartbeat)
fails to start. Despite the name, it does not currently surface from
`push`/`receive` waiting for a reply — Aquamarine does not correlate
replies to pushes for you (see
[Channel lifecycle](/guides/channels/#refs-and-replies)).

## A complete handler

```gleam
import aquamarine
import aquamarine/error.{
  ChannelClosed, DecodeFailed, JoinRejected, ReplyTimeout, Transport,
}

case aquamarine.receive(channel) {
  Ok(incoming) -> handle(incoming)
  Error(ChannelClosed) -> reconnect()
  Error(Transport(t)) -> log_transport_error(t)
  Error(DecodeFailed(d)) -> log_decode_error(d)
  Error(JoinRejected(reason)) -> give_up(reason)
  Error(ReplyTimeout) -> retry()
}
```
