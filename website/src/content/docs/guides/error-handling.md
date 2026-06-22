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

Wraps a failure from the underlying Stratus-backed WebSocket transport.
Returned by `connect`, `push`, and `close` whenever the socket itself
misbehaves. The inner `TransportError` classifies the failure further:

| Variant | Meaning |
| --- | --- |
| `HandshakeFailed(reason)` | The WebSocket upgrade failed or the Stratus actor could not complete startup. |
| `SocketConnectionFailed(reason)` | Opening the underlying socket failed before the channel could join. |
| `SocketSendFailed(reason)` | Sending a WebSocket frame failed. |
| `SocketReceiveFailed(reason)` | Receiving a WebSocket frame failed after startup. |
| `InvalidTransportConfig(reason)` | The host, port, path, scheme, or request configuration was invalid. |
| `UnexpectedTransportFailure(reason)` | A transport failure did not fit a stable public category. |

### `JoinRejected(reason)`

`connect` saw a `phx_reply` for the join, but its `status` was not
`"ok"`. The `reason` is the reply's status string (e.g. `"unauthorized"`),
or `"malformed reply"` if the payload could not be decoded.

### `ChannelClosed`

The channel is no longer usable. Returned when the runtime sees a close
event or the underlying socket closes.

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
`push` waiting for a reply — Aquamarine does not correlate replies to
pushes for you (see [Channel lifecycle](/guides/channels/#refs-and-replies)).

## A complete handler

```gleam
import aquamarine
import aquamarine/error.{
  ChannelClosed, DecodeFailed, JoinRejected, ReplyTimeout, Transport,
}

let handlers =
  aquamarine.handlers(
    on_message: fn(state, incoming) {
      handle(incoming)
      aquamarine.continue(state)
    },
    on_error: fn(state, err) {
      case err {
        Transport(t) -> log_transport_error(t)
        DecodeFailed(d) -> log_decode_error(d)
        ChannelClosed -> reconnect()
        JoinRejected(reason) -> give_up(reason)
        ReplyTimeout -> retry()
      }
      aquamarine.stop(state)
    },
    on_closed: fn(state) {
      reconnect()
      aquamarine.stop(state)
    },
    on_joined: fn(state, _payload) {
      aquamarine.continue(state)
    },
  )
```
