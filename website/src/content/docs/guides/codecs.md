---
title: Codecs
description: How Aquamarine stays protocol-agnostic, and how to plug in a codec for a different wire format.
---

Aquamarine's channel runtime does not know what a Phoenix frame looks
like. It delegates every encode/decode decision — and the names of the
protocol's special events — to a [`Codec`](https://hexdocs.pm/aquamarine/aquamarine/codec.html)
value supplied through `aquamarine.config(...)`.

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
    join_event: String,
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

- On `connect`, the channel actor calls
  `codec.encode_join(join_ref, topic, payload)` and sends the resulting
  text, then waits for an inbound frame whose decoded `event ==
  codec.reply_event` and `ref == join_ref`.
- On `push`, the channel actor calls
  `codec.encode_push(join_ref, ref, topic, event, payload)`.
- On each heartbeat tick, the channel actor calls
  `codec.encode_heartbeat(ref)`.
- For inbound text, the channel actor calls `codec.decode(text)`, then
  dispatches the decoded frame to callbacks or swallows protocol
  heartbeat replies before they reach user code.

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

pub fn my_codec() -> codec.Codec {
  Codec(
    decode: my_decode,
    encode_join: my_encode_join,
    encode_push: my_encode_push,
    encode_heartbeat: my_encode_heartbeat,
    join_event: "join",
    reply_event: "reply",
    close_event: "close",
    error_event: "error",
    heartbeat_topic: "_heartbeat",
  )
}
```

Then pass it through `aquamarine.config(..., codec: my_codec())`. The
channel runtime will use it for every wire interaction; nothing in
`aquamarine/channel` needs to change.

### Decode errors

Your `decode` function returns `Result(Incoming, DecodeError)`. Use the
two provided variants to classify failures:

- `InvalidJson(reason)` — the text was not valid JSON.
- `InvalidFormat(reason)` — the JSON did not match the protocol's
  expected shape.

Both are wrapped by the channel as `AquamarineError.DecodeFailed`.
