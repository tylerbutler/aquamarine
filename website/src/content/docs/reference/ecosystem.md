---
title: Beryl ecosystem
description: How Aquamarine, Beryl, Phoenix codecs, Gluegun, and Roost fit together.
---

Aquamarine is one piece of a small constellation of Gleam packages that
together provide a Phoenix Channels–compatible client/server stack on
the BEAM. This page maps out where Aquamarine sits and what each of its
neighbours does.

## Package map

<div class="aqua-ecosystem-map" role="img" aria-label="Aquamarine connects to Beryl over Gluegun, uses aquamarine/phoenix for Phoenix frames, and shares Roost frame types with Beryl.">
  <div class="aqua-ecosystem-map__row">
    <div class="aqua-ecosystem-node">
      <strong>Beryl</strong>
      <span>Phoenix-compatible channel server</span>
    </div>
    <div class="aqua-ecosystem-node" data-primary="true">
      <strong>Aquamarine</strong>
      <span>Channel client runtime</span>
    </div>
    <div class="aqua-ecosystem-node">
      <strong>Gluegun</strong>
      <span>WebSocket transport</span>
    </div>
  </div>
  <div class="aqua-ecosystem-link">Beryl <-> WebSocket transport <-> Aquamarine</div>
  <div class="aqua-ecosystem-map__row">
    <div class="aqua-ecosystem-node">
      <strong>Roost</strong>
      <span>Phoenix frame types</span>
    </div>
    <div class="aqua-ecosystem-node">
      <strong>aquamarine/phoenix</strong>
      <span>Codec adapter</span>
    </div>
  </div>
  <div class="aqua-ecosystem-link">Roost keeps Phoenix frame encoding consistent between Beryl and the bundled codec.</div>
</div>

## What each package does

- **[Beryl](https://github.com/tylerbutler/beryl)** — the server side
  of the ecosystem. A Phoenix-compatible channel server written in
  Gleam. Aquamarine talks to Beryl, but is not coupled to it — any
  Phoenix Channels–compatible server works.
- **Aquamarine** — the protocol-agnostic client runtime. Owns the
  channel lifecycle (connect, join, push, receive, heartbeat, close)
  and delegates wire format decisions to a configurable codec.
- **`aquamarine/phoenix`** — the bundled codec adapter that makes
  Aquamarine speak the Phoenix Channels wire format. See
  [Phoenix and Beryl](/guides/phoenix/) for usage.
- **[Gluegun](https://github.com/tylerbutler/gluegun)** — the
  underlying WebSocket transport library Aquamarine uses to actually
  open the socket and move bytes.
- **[Roost](https://github.com/tylerbutler/roost)** — the Phoenix
  frame library. Provides the canonical
  `[join_ref, ref, topic, event, payload]` encode/decode and the
  protocol event-name constants. Both Aquamarine's Phoenix codec and
  the Beryl server build on it, which is why they stay in sync.

## Swapping pieces

The diagram above also shows what you can and cannot replace:

- **Codec is pluggable.** Replace `aquamarine/phoenix` with your own
  [`Codec`](/guides/codecs/) to talk to a different protocol — the
  channel runtime does not change.
- **Server is pluggable.** Aquamarine has no compile-time dependency on
  Beryl. Anything that speaks the codec you configured will work.
- **Transport is fixed.** Gluegun is currently the only transport
  Aquamarine uses for production `connect` calls. The internal
  `Transport` seam is `@internal` and exists for testing.
