---
title: Supervision
description: Putting a socket in your supervision tree, reaching it by name, and what a restart means for your handles.
---

A socket can live in your application's supervision tree rather than be
babysat by whatever process happened to open it.

```gleam
import aquamarine/phoenix
import aquamarine/socket
import aquamarine/transport
import gleam/otp/static_supervisor

pub const socket_name = "app_channel_socket"

pub fn start_tree() {
  let name = socket.new_name(socket_name)

  let config =
    socket.config(
      scheme: transport.Wss,
      host: "example.com",
      port: 443,
      path: "/socket/websocket",
      codec: phoenix.codec(),
    )

  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(socket.supervised(config, name))
  |> static_supervisor.start
}
```

## Named sockets

`supervised` requires a name, and that is deliberate. The supervisor captures
the started socket, so without a name the caller has no way to reach it at
all — and a restarted socket is a *different process*, so a handle bound to a
pid would be worthless the moment it mattered.

```gleam
let sock = socket.named(name)
socket.push(sock, "room:lobby", "ping", json.object([]))
```

`socket.named` is safe to build before the socket exists and safe to keep
across a restart — it resolves at send time. A process that never saw the
handle can push, join, or watch through the name alone, without the socket
being threaded through its own state.

Sends to a name nobody currently holds are silently dropped, as OTP sends
always are.

## Restart strategy

The child is `Transient`: restarted if it dies abnormally, not restarted if
it exits normally. `socket.close` exits normally, so a deliberate teardown is
not second-guessed into a reconnect by the supervisor.

## Restart is not reconnect

These are different mechanisms and it matters which one is carrying you.

| | Reconnect | Supervisor restart |
| --- | --- | --- |
| Triggered by | The connection dropping | The actor crashing |
| The actor | Stays alive | Is replaced |
| Joined topics | Rejoined automatically | **Gone** |
| Your `Channel` handles | Still valid | **Stale** |

A dropped connection never reaches the supervisor. The actor stays alive on
purpose — so a caller mid-flight gets `ChannelClosed` back rather than having
its message vanish into a dead mailbox — and reconnects itself. See
[Reconnect](/guides/reconnect/).

Supervision is the backstop for a socket that *crashed*. After a restart:

- The new socket has **no joined channels**. Restart does not rejoin.
- Every `Channel` handle from before the restart is **stale**. Its events
  subject belonged to the dead actor and will never receive again — it will
  simply time out forever.

There is no way to detect this from the handle. If your application holds
`Channel` values across a possible restart, hold them somewhere you can
replace them, and re-`join` after a restart rather than assuming they
survived.

## Related

- [Reconnect](/guides/reconnect/) — the mechanism that *does* keep your
  handles.
- [One socket, many topics](/guides/multi-topic/) — what to join on it.
