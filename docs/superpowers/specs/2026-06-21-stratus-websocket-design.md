# Stratus WebSocket Actor Design

## Goal

Replace Aquamarine's Gluegun-based WebSocket runtime with Stratus and use the migration to simplify the pre-1.0 public API around an actor-owned channel lifecycle.

The new API may break compatibility. Aquamarine should favor Stratus' actor model instead of preserving the current caller-owned, blocking `receive(channel)` model.

## Non-goals

- Do not support Gluegun and Stratus as parallel production transports.
- Do not expose Stratus connection details in Aquamarine's public API.
- Do not keep protocol-specific Phoenix behavior in the channel runtime.

## Architecture

Aquamarine will become an actor-based channel client built directly on Stratus. `aquamarine.connect` and `aquamarine/channel.connect` will start a channel actor instead of returning a handle that the caller uses for blocking receives.

The channel actor owns:

- the Stratus WebSocket connection,
- the protocol codec,
- join lifecycle state,
- ref generation,
- heartbeat scheduling,
- inbound message dispatch, and
- shutdown cleanup.

The current internal `aquamarine/transport` seam should disappear or shrink to test-only helpers. Stratus already owns connect, send, receive, ping/pong handling, and close behavior inside its actor, so a socket-like transport wrapper would add indirection without preserving the intended runtime model.

`Channel(state)` remains opaque. It wraps the started channel actor subject and may be used from any process to send commands such as `push` and `close`.

## Public API

The public API shifts from pull-based receives to callback-based handlers.

Current shape:

```gleam
connect(...) -> Result(Channel, AquamarineError)
receive(channel) -> Result(Incoming, AquamarineError)
```

New shape:

```gleam
connect(config, handlers, initial_state) -> Result(Channel(state), AquamarineError)
push(channel, event, payload) -> Result(Nil, AquamarineError)
close(channel) -> Result(Nil, AquamarineError)
```

Handlers carry typed user state through the channel actor. The exact names can change during implementation, but the API should cover these lifecycle points:

- `on_joined(state, reply_payload) -> Next(state)`
- `on_message(state, incoming) -> Next(state)`
- `on_error(state, AquamarineError) -> Next(state)`
- `on_closed(state) -> Next(state)`

`Next(state)` should let the callback continue with a new state or stop the channel. Aquamarine should remove `receive(channel)` rather than keep it as a compatibility wrapper.

## Connect and runtime flow

`connect` builds a Stratus request from Aquamarine's host, port, and path configuration, starts a Stratus actor, and returns only after the WebSocket handshake and channel join are complete or failed.

The actor then follows this flow:

1. Open the Stratus WebSocket.
2. Start or initialize ref generation.
3. Send the encoded join frame.
4. Decode inbound frames until the matching join reply arrives.
5. Return `JoinRejected`, `DecodeFailed`, `ChannelClosed`, or a transport startup error if the join cannot complete.
6. Start heartbeat after a successful join.
7. Dispatch decoded application messages to `on_message`.
8. Swallow heartbeat replies.
9. Treat protocol close/error events and WebSocket close frames as channel closure.
10. Stop heartbeat and release actor resources during shutdown.

Push commands ask the channel actor for the next ref, encode a push through the configured codec, and send the text frame through Stratus. Close commands stop heartbeat, send a normal close frame when possible, and stop the actor.

## Error model

Startup failures still return `Result(_, AquamarineError)` from `connect`.

After startup, the actor owns inbound processing, so runtime failures are delivered to callbacks instead of returned from `receive`. `on_error` should receive decode failures, transport failures, and unexpected internal failures. `on_closed` should receive normal server or client closure.

`TransportError` should stop mirroring Gluegun's error variants. Replace it with Aquamarine-owned categories that fit Stratus and remain stable:

- handshake failure,
- socket connection failure,
- socket send failure,
- socket receive failure,
- invalid transport configuration, and
- unexpected transport failure.

Each category may carry a string reason. The exact constructors should be chosen while implementing against Stratus' `SocketReason`, handshake errors, and actor start errors.

## Codec boundary

Keep the existing codec boundary. Protocol frame shape, event names, join encoding, push encoding, and decode behavior remain in `aquamarine/codec` and protocol adapters such as `aquamarine/phoenix`.

The channel actor should only know that the codec can encode joins and pushes, decode inbound text, identify reply events, identify heartbeat replies, and identify close/error events.

## Testing

Codec tests should remain unchanged.

Channel tests should move from fake socket scripts to actor-driven tests that assert:

- successful join calls `on_joined`,
- application messages call `on_message` with updated state,
- client pushes send encoded frames with refs,
- heartbeat starts after join and swallows heartbeat replies,
- join rejection returns `Error(JoinRejected(_))`,
- malformed join replies return a deterministic error,
- runtime decode failures call `on_error`,
- close/error events call `on_closed` or `on_error`, and
- close stops heartbeat and the channel actor.

The existing Mist/Beryl integration tests remain the main end-to-end validation for real WebSocket behavior. They should be rewritten around callback state rather than `receive(channel)`.

## Documentation impact

Update README and website docs that mention Gluegun, blocking `receive`, process ownership, or transport errors. The docs should describe Aquamarine as a Stratus-backed, actor-owned channel client.

The ecosystem reference should replace Gluegun with Stratus and remove language that says the transport is fixed to Gluegun.

## Migration impact

This is a breaking pre-1.0 change. Existing users who call `receive(channel)` must move message handling into callbacks supplied at connect time. Existing `push` and `close` call sites should remain similar because they stay command-style operations on an opaque channel handle.
