---
target: website
total_score: 29
p0_count: 0
p1_count: 2
timestamp: 2026-06-20T19-04-02Z
slug: website-src-content-docs-index-mdx
---
#### Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Navigation/search/theme state are handled by Starlight; no issue for a mostly static docs site. |
| 2 | Match System / Real World | 3 | Language fits Gleam/Phoenix developers, but the hero leads with Phoenix Channels before clarifying Aquamarine is protocol-agnostic. |
| 3 | User Control and Freedom | 3 | Sidebar, search, theme selector, edit links, and normal docs navigation give good escape paths. |
| 4 | Consistency and Standards | 3 | Strong Starlight consistency; custom brand system is thin enough that the site can feel default-template rather than intentionally Aquamarine. |
| 5 | Error Prevention | 2 | Examples sometimes model `let _` / `Error(_)` patterns before teaching safer handling, which can normalize ignoring failures. |
| 6 | Recognition Rather Than Recall | 3 | Cards and sidebar expose the major paths; the runtime model still requires reading prose instead of being recognized visually. |
| 7 | Flexibility and Efficiency | 3 | Search, Ctrl+K, generated API docs, and llms.txt support efficient expert use. |
| 8 | Aesthetic and Minimalist Design | 3 | Clean and restrained, but the homepage is largely default Starlight hero + card grid. |
| 9 | Error Recovery | 2 | Error docs exist, but the homepage/getting-started examples do not make recovery paths concrete enough at first contact. |
| 10 | Help and Documentation | 4 | The docs are concise, searchable, and task-focused, with guides for lifecycle, codecs, Phoenix/Beryl, errors, and API. |
| **Total** | | **29/40** | **Good foundation; needs stronger brand/comprehension layer.** |

#### Anti-Patterns Verdict

**LLM assessment**: This does not scream AI-generated. It avoids the worst tells: no gradient text, no hero metrics, no glass cards, no repeated all-caps eyebrows, no decorative shadow stacks, and no beige SaaS drift. The risk is the opposite: it is so deferential to default Starlight that it reads more like a lightly themed docs template than a memorable library site. For a careful systems library that is mostly acceptable, but the homepage misses the chance to make the runtime model instantly legible.

**Deterministic scan**: `detect.mjs --json website/src/content/docs/index.mdx` and `detect.mjs --json website/src/content/docs` both returned `[]`. No deterministic slop findings.

**Visual overlays**: No reliable user-visible overlay is available in this CLI session because browser automation / mutable page injection tools are not exposed. Fallback signal used: source review, generated HTML inspection, deterministic detector, build output, and contrast calculation.

#### Overall Impression

Aquamarine feels calm, technical, and trustworthy. The content is stronger than the visual storytelling: the docs explain the lifecycle well once you read, but the first screen does not yet show the core mental model that makes the library distinctive.

The biggest opportunity is to turn the homepage from “Starlight docs with a custom palette” into “the clear channel”: one immediate visual explanation of connect -> join -> heartbeat/ref -> push/receive -> close, supported by the four-function API.

#### What's Working

1. The color system is disciplined. Dark navy + aquamarine matches the product name and avoids generic warm SaaS neutrals. Key contrast pairs are healthy in dark mode: body text on canvas is 11.19:1, subtle text is 4.84:1, and accent on canvas is 7.84:1.
2. The information architecture is compact and developer-shaped. Start here, Guides, and Reference match the evaluation-to-implementation path for a small library.
3. The copy has unusually good technical specificity. Phrases like “owns the lifecycle” and “delegates the on-the-wire format to a pluggable Codec” communicate the real boundary instead of marketing vapor.

#### Priority Issues

**[P1] Runtime model is explained, not shown**

**Why it matters**: Aquamarine’s differentiator is architectural: protocol-agnostic lifecycle ownership with Phoenix/Beryl compatibility via codec. The homepage asks readers to assemble that model from prose and snippets. First-time evaluators should understand it in one glance.

**Fix**: Add a compact homepage “channel lifecycle” visual after the hero or alongside the API shape: `connect` opens socket + joins, heartbeat/ref actor runs in background, `push` sends outbound events, `receive` filters inbound frames, `close` cleans up. Keep it textual/diagrammatic, not decorative. This can replace or reduce the generic card-grid feel.

**Suggested command**: `$impeccable layout website/src/content/docs/index.mdx`

**[P1] Brand expression is too close to default Starlight**

**Why it matters**: The site is trustworthy, but not yet memorable. A visitor could remember “a dark Starlight docs site” more easily than “Aquamarine, the clear channel runtime.” That weakens recall for a young library.

**Fix**: Preserve Starlight affordances, but add one distinctive homepage composition: an aquamarine signal line, channel flow strip, or nav rhythm tied to the logo/clear-channel metaphor. Avoid gradients and ornamental diagrams; make the identity carry comprehension.

**Suggested command**: `$impeccable bolder website/src/content/docs/index.mdx`

**[P2] First examples under-model error handling**

**Why it matters**: The product promise includes explicit errors, but the first examples either `io.debug(error)`, `let _ = close`, or `Error(_) -> Nil`. That teaches readers that errors are visible but not worth handling.

**Fix**: Keep snippets short, but show a named error path in the homepage or Getting Started: match `Error(error)` and point to one recovery decision. Replace at least one `Error(_) -> Nil` with intent-bearing handling copy.

**Suggested command**: `$impeccable clarify website/src/content/docs/index.mdx website/src/content/docs/getting-started.md`

**[P2] Performance footprint from diagrams deserves a design/tech pass**

**Why it matters**: Build output emits large Mermaid-related chunks (`wardley` 612 KB, `mermaid.core` 607 KB, `cytoscape` 442 KB) and Vite warns about chunks over 500 KB. Even if route-loaded, the docs only contain one Mermaid package map, so the design cost of that diagram may be disproportionate.

**Fix**: Audit whether Mermaid code is loaded only on the ecosystem page. If not, isolate it. If yes, consider replacing the single package map with static SVG/HTML so the docs feel lighter and faster.

**Suggested command**: `$impeccable optimize website`

**[P3] Light-mode accent contrast is borderline for normal text**

**Why it matters**: `#1e8e84` on white is 3.99:1, below WCAG AA for normal-size text. Starlight may use accent mostly for larger links/buttons or with different backgrounds, but the token itself is risky if reused for body-size link text.

**Fix**: Darken light-mode `--sl-color-accent` or ensure normal-size links use `--sl-color-accent-high` / a darker link token. Keep aquamarine identity; do not mute it into gray.

**Suggested command**: `$impeccable audit website/src/styles/custom.css`

#### Persona Red Flags

**Alex (Impatient Gleam power user)**: Alex can reach code quickly via Getting Started and API Overview, and search/Ctrl+K helps. Red flag: the homepage does not provide a copy-paste minimal “connect + push + receive” success path before the longer explanatory flow, so Alex still has to scan multiple sections for the shortest implementation route.

**Jordan (Phoenix/Beryl-aware but Aquamarine-new developer)**: Jordan gets strong prose, but the first-screen claim “Connect Gleam processes to Phoenix Channels…” may make the protocol-agnostic promise feel secondary. Red flag: “Beryl-style,” “Codec,” “join_ref,” and “phx_reply” appear before a visual model anchors them.

**Sam (Accessibility-dependent user)**: Starlight gives a solid baseline: skip link, semantic headings, labeled search, theme selector, alt text, and strong dark-mode contrast. Red flag: light-mode accent contrast is only 3.99:1 against white, so any normal-size accent-colored text can fail AA.

**Casey (Distracted mobile reader)**: Starlight’s mobile navigation should be dependable, and the docs are concise. Red flag: the splash hero uses a 400x400 logo plus H1/tagline/actions, which may push the first useful technical explanation below the fold on small screens.

#### Minor Observations

- The version badge is useful, but “Pre-1.0 package” could work harder by linking directly to stability expectations or changelog once those exist.
- The homepage cards are useful, but they are structurally generic. They should either be reordered around the lifecycle or visually tied to the channel model.
- The site uses Metropolis consistently, which is fine for identity preservation, but the current type treatment does not create many memorable moments beyond Starlight defaults.
- The generated site includes an accessible search/modal structure; keep this rather than replacing it with custom search UI.

#### Questions to Consider

- What should the first screen make impossible to miss: “Phoenix-compatible now,” “protocol-agnostic by design,” or “four functions for the lifecycle”? Pick one primary message and make the others supporting.
- Could the homepage teach the lifecycle with one diagram before it asks the reader to parse a code block?
- Is the Mermaid ecosystem diagram worth the JS cost, or would a static authored diagram communicate the same model faster?
