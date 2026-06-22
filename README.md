# Aquamarine

Aquamarine is the protocol-agnostic, Stratus-backed channel runtime for Gleam.
It owns the WebSocket actor lifecycle while protocol packages supply codecs.

For Phoenix and Beryl compatibility, configure Aquamarine with `aquamarine/phoenix.codec()`.

## Quick start

```gleam
import aquamarine
import aquamarine/codec.{type Incoming}
import aquamarine/error.{type AquamarineError}
import aquamarine/phoenix
import gleam/json

type State {
  State(messages: Int)
}

let handlers =
  aquamarine.handlers(
    on_joined: fn(state, _reply_payload) {
      aquamarine.continue(state)
    },
    on_message: fn(state, _incoming: Incoming) {
      aquamarine.continue(State(messages: state.messages + 1))
    },
    on_error: fn(state, _err: AquamarineError) {
      aquamarine.continue(state)
    },
    on_closed: fn(state) {
      aquamarine.continue(state)
    },
  )

let assert Ok(channel) =
  aquamarine.connect(
    aquamarine.config(
      host: "localhost",
      port: 4000,
      path: "/socket/websocket",
      topic: "room:lobby",
      payload: json.object([]),
      codec: phoenix.codec(),
    ),
    handlers,
    State(messages: 0),
  )
```
