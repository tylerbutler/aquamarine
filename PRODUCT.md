# Product

## Register

product

## Users

Gleam developers on the BEAM (Erlang target) building realtime applications that
talk to Beryl-style or Phoenix Channels WebSocket servers. They arrive at the
docs in a working context: installing the package, wiring up `connect`/`push`/
`receive`/`close`, choosing or writing a `Codec`, and debugging connection,
heartbeat, or lifecycle issues. The core job is **reading and reference** —
scanning for the right function, copying a code block that works, and
understanding the channel lifecycle well enough to trust it in production.

## Product Purpose

The documentation site for Aquamarine, a protocol-agnostic, Beryl-style
WebSocket channel client runtime for Gleam. The site exists to get a developer
from "never heard of it" to "connected and pushing frames" with minimal
friction, and to serve as the durable reference for the channel lifecycle,
codec boundary, heartbeats/refs, and the typed error surface. Success looks
like: a developer finds the answer in one or two hops, trusts the code samples
without modification, and never feels the docs are fighting the content.

## Brand Personality

Simple, systemic, bold. The voice is confident and precise — it states how the
runtime behaves without hedging, and treats the reader as a capable engineer.
"Simple" means no ceremony: short paths to working code, plain language over
jargon. "Systemic" means the docs reflect the library's architecture — a clean
codec boundary, an explicit lifecycle, composable parts — so structure carries
meaning. "Bold" means committed visual and editorial choices: crisp hierarchy,
decisive accent use, no apologetic filler.

## Anti-references

- Generic SaaS-cream landing pages and warm-neutral "magazine" templates.
- Playful, illustration-heavy, mascot-driven docs that bury the reference under
  personality.
- Low-contrast, light-gray-on-tinted-white body text presented as "elegant."
- Cluttered, ad-laden, or deeply-nested-card documentation that makes scanning
  hard.

## Design Principles

- **Shortest path to working code.** Every page should put a copyable, correct
  example within reach; reference beats prose.
- **Structure mirrors the system.** Information architecture should echo the
  library's own boundaries (lifecycle, codec, refs/heartbeats, errors) so the
  docs teach the mental model by their shape.
- **Confident restraint.** Crisp, dense, Stripe/Linear-grade hierarchy. Color
  and motion are deployed deliberately, never as decoration.
- **Legibility is non-negotiable.** Contrast and scannability win over any
  stylistic flourish; the reader's eye is the constraint.
- **Trustworthy by default.** Accurate code, stable links, predictable
  navigation — the docs should feel as dependable as the runtime they describe.

## Accessibility & Inclusion

Target WCAG 2.1 AA across both themes: body text ≥4.5:1, large text ≥3:1,
including code blocks, inline code, and link states. Provide solid reduced-motion
support — every animation needs a `prefers-reduced-motion: reduce` alternative
(crossfade or instant). Dark mode is the default; the light theme must meet the
same contrast bar. Keep focus states visible and navigation keyboard-complete.
