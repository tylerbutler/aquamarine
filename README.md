# Aquamarine

Aquamarine is the protocol-agnostic Beryl-style channel client runtime for Gleam.
It provides the client runtime layer while protocol packages supply codecs.

For Phoenix and Beryl compatibility, configure Aquamarine with `aquamarine/phoenix.codec()`.

## Topicless protocols

Set `Codec.topicless_events` to `True` for protocols whose event frames have no
topic. Aquamarine routes an empty-topic event to the socket's sole channel and
rejects a second topic with `TopiclessSocketOccupied`, including while the first
join is pending. Close and error events remove that channel from reconnect state.
They also fail its pending calls. Aquamarine drops stale referenced replies for
topicless codecs so an earlier join cannot close a replacement channel.

Decode heartbeat replies with a distinct, nonempty `heartbeat_topic`; Aquamarine
does not forward them to the channel. Codecs that route by topic, including
Phoenix, must set the new `topicless_events` field to `False`.

## Quick start

```gleam
import aquamarine
import aquamarine/phoenix
import gleam/json

let assert Ok(channel) =
  aquamarine.connect(
    host: "localhost",
    port: 4000,
    path: "/socket/websocket",
    topic: "room:lobby",
    payload: json.object([]),
    codec: phoenix.codec(),
  )
```
