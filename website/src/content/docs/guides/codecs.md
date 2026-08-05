---
title: Codecs
description: How Aquamarine stays protocol-agnostic, and how to plug in a codec for a different wire format.
---

Aquamarine's channel runtime does not know what a Phoenix frame looks
like. It delegates every encode/decode decision — and the names of the
protocol's special events — to a [`Codec`](https://github.com/tylerbutler/aquamarine/blob/main/src/aquamarine/codec.gleam)
value supplied at `connect` time.

This is what makes the same client work against Phoenix Channels, Beryl,
or any other server that speaks a compatible message-with-ref protocol.

## The `Codec` record

A codec bundles the functions Aquamarine needs to read and write frames,
plus the strings the channel uses to recognise protocol-level events:

```gleam
pub type Codec {
  Codec(
    decode: fn(String) -> Result(Incoming, DecodeError),
    encode_join: fn(String, String, json.Json) -> String,
    encode_push: fn(String, String, String, String, json.Json) -> String,
    encode_heartbeat: fn(String) -> String,
    matches_reply: fn(Incoming, String) -> Bool,
    reply_status: fn(Incoming) -> Result(Nil, String),
    join_event: String,
    leave_event: String,
    reply_event: String,
    close_event: String,
    error_event: String,
    heartbeat_topic: String,
  )
}
```

The decoded shape is also codec-defined:

```gleam
pub type Incoming {
  Incoming(
    join_ref: Option(String),
    ref: Option(String),
    topic: String,
    event: String,
    payload: Dynamic,
  )
}
```

`payload` is a `Dynamic` so the channel runtime never has to know your
schema — decoders in your own code can turn it into typed records.

## How the channel uses it

Everything below happens inside the socket actor, which is the only thing
that touches a codec.

- On a join, the socket calls `codec.encode_join(join_ref, topic, payload)`
  and sends the resulting text, then waits for an inbound frame for which
  `codec.matches_reply(incoming, join_ref)` is `True`. It then calls
  `codec.reply_status(incoming)`: `Ok(Nil)` joins, `Error(reason)` rejects.
  Ref-based protocols match on `ref`; refless protocols (e.g. Socket.IO) can
  match on event name alone.
- On a push, the socket calls
  `codec.encode_push(join_ref, ref, topic, event, payload)`. A `leave` is the
  same call with `leave_event` and an empty payload.
- The heartbeat calls `codec.encode_heartbeat(ref)` on every tick.
- On every inbound frame, the socket calls `codec.decode(text)`, uses
  `matches_reply` to see whether it answers anyone waiting on a ref, and
  otherwise routes it by `incoming.topic`. `close_event` and `error_event`
  terminate that topic's channel.

`matches_reply` is the whole of reply correlation. A codec that cannot
correlate simply never matches, and callers waiting on a reply fall back to
their timeout rather than hanging.

Because the socket must decode every frame to read its topic before it can
route, **the codec belongs to the socket, not to a channel** — one connection
speaks one wire protocol, matching Phoenix's one-serializer-per-socket
model.

## The bundled Phoenix codec

`aquamarine/phoenix.codec()` returns a `Codec` wired up to the
[Roost](https://github.com/tylerbutler/roost) frame library, which
implements Phoenix's `[join_ref, ref, topic, event, payload]` JSON wire
format. See [Phoenix and Beryl](/guides/phoenix/) for usage.

## Writing your own codec

To support a different protocol, construct a `Codec` value with your own
encode/decode functions:

```gleam
import aquamarine/codec.{Codec, Incoming, InvalidFormat}
import gleam/json
import gleam/option

pub fn my_codec() -> codec.Codec {
  Codec(
    decode: my_decode,
    encode_join: my_encode_join,
    encode_push: my_encode_push,
    encode_heartbeat: my_encode_heartbeat,
    matches_reply: fn(in, join_ref) {
      in.event == "reply" && in.ref == option.Some(join_ref)
    },
    reply_status: fn(_in) { Ok(Nil) },
    join_event: "join",
    reply_event: "reply",
    close_event: "close",
    error_event: "error",
    heartbeat_topic: "_heartbeat",
  )
}
```

Then pass it to `socket.connect(..., codec: my_codec())`, or to
`aquamarine.connect(..., codec: my_codec())` for the single-topic path. The
channel runtime will use it for every wire interaction; nothing in
`aquamarine/channel` needs to change.

### Refless protocols

`matches_reply` lets the codec decide how a join reply is correlated, so
protocols without a `ref` work too. A Socket.IO-style codec can match the
join purely by event name:

```gleam
matches_reply: fn(in, _join_ref) { in.event == "connect_document_success" },
reply_status: fn(_in) { Ok(Nil) },
```

### Decode errors

Your `decode` function returns `Result(Incoming, DecodeError)`. Use the
two provided variants to classify failures:

- `InvalidJson(reason)` — the text was not valid JSON.
- `InvalidFormat(reason)` — the JSON did not match the protocol's
  expected shape.

Both are wrapped by the channel as `AquamarineError.DecodeFailed`.
