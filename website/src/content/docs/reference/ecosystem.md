---
title: Beryl ecosystem
description: How Aquamarine, Beryl, Phoenix codecs, Gluegun, and Roost fit together.
---

Aquamarine is one piece of a small constellation of Gleam packages that
together provide a Phoenix Channels–compatible client/server stack on
the BEAM. This page maps out where Aquamarine sits and what each of its
neighbours does.

## Package map

<figure
  class="aqua-ecosystem-map"
  role="img"
  aria-label="Aquamarine, the channel client runtime, connects to the Beryl channel server over a WebSocket transport provided by Gluegun. Aquamarine uses the aquamarine/phoenix codec adapter, which builds on the Roost Phoenix frame library. The Beryl server also builds on Roost, which keeps their frame encoding in sync."
>
  <svg class="aqua-diagram" viewBox="0 0 600 400" xmlns="http://www.w3.org/2000/svg" aria-hidden="true" focusable="false">
    <title>Beryl ecosystem package map</title>
    <defs>
      <marker
        id="aqua-dia-arrow"
        class="aqua-dia-marker"
        viewBox="0 0 10 10"
        refX="9"
        refY="5"
        markerWidth="7"
        markerHeight="7"
        orient="auto-start-reverse"
      >
        <path class="aqua-dia-arrowhead" d="M0,0 L10,5 L0,10 z" />
      </marker>
    </defs>
    <!-- Edges -->
    <line
      class="aqua-dia-line"
      x1="230" y1="83" x2="370" y2="83"
      marker-start="url(#aqua-dia-arrow)"
      marker-end="url(#aqua-dia-arrow)"
    />
    <line
      class="aqua-dia-line"
      x1="135" y1="122" x2="135" y2="210"
      marker-end="url(#aqua-dia-arrow)"
    />
    <polyline
      class="aqua-dia-line"
      points="135,288 135,355 200,355"
      marker-end="url(#aqua-dia-arrow)"
    />
    <polyline
      class="aqua-dia-line"
      points="465,122 465,355 400,355"
      marker-end="url(#aqua-dia-arrow)"
    />
    <!-- Edge labels -->
    <text class="aqua-dia-label" x="300" y="70" text-anchor="middle">via Gluegun</text>
    <text class="aqua-dia-label" x="300" y="104" text-anchor="middle">WebSocket</text>
    <text class="aqua-dia-label" x="150" y="170" text-anchor="start">uses codec</text>
    <text class="aqua-dia-label" x="150" y="330" text-anchor="start">builds on</text>
    <text class="aqua-dia-label" x="450" y="330" text-anchor="end">builds on</text>
    <!-- Nodes -->
    <g>
      <rect class="aqua-dia-node aqua-dia-node--primary" x="40" y="44" width="190" height="78" />
      <text class="aqua-dia-name" x="135" y="78" text-anchor="middle">Aquamarine</text>
      <text class="aqua-dia-sub" x="135" y="101" text-anchor="middle">Client runtime</text>
    </g>
    <g>
      <rect class="aqua-dia-node" x="370" y="44" width="190" height="78" />
      <text class="aqua-dia-name" x="465" y="78" text-anchor="middle">Beryl</text>
      <text class="aqua-dia-sub" x="465" y="101" text-anchor="middle">Channel server</text>
    </g>
    <g>
      <rect class="aqua-dia-node" x="40" y="210" width="190" height="78" />
      <text class="aqua-dia-name aqua-dia-name--sm" x="135" y="244" text-anchor="middle">aquamarine/phoenix</text>
      <text class="aqua-dia-sub" x="135" y="267" text-anchor="middle">Codec adapter</text>
    </g>
    <g>
      <rect class="aqua-dia-node" x="200" y="320" width="200" height="70" />
      <text class="aqua-dia-name" x="300" y="352" text-anchor="middle">Roost</text>
      <text class="aqua-dia-sub" x="300" y="373" text-anchor="middle">Phoenix frame types</text>
    </g>
  </svg>
  <figcaption class="aqua-ecosystem-caption">
    Roost keeps the Phoenix frame encoding consistent between Beryl and the
    bundled <code>aquamarine/phoenix</code> codec.
  </figcaption>
</figure>

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
