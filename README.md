# Aquamarine

Aquamarine is the protocol-agnostic Beryl-style channel client runtime for Gleam.
It provides the client runtime layer while protocol packages supply codecs.

For Phoenix and Beryl compatibility, configure Aquamarine with `aquamarine/phoenix.codec()`.

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
