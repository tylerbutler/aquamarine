---
target: website
total_score: 29
p0_count: 0
p1_count: 2
timestamp: 2026-06-20T04-10-01Z
slug: website-src-content-docs-index-mdx
---
#### Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Docs navigation is clear, but the homepage does not surface package/version/runtime confidence signals. |
| 2 | Match System / Real World | 2 | The hero leads with "Beryl-style" before anchoring in the more recognizable Phoenix Channels vocabulary. |
| 3 | User Control and Freedom | 4 | Starlight navigation, hero actions, cards, and GitHub link give clear exits and next paths. |
| 4 | Consistency and Standards | 4 | Starlight conventions and the custom color tokens are cohesive. |
| 5 | Error Prevention | 2 | The first code sample uses `let assert Ok(channel)`, which teaches a panic-on-failure path without warning. |
| 6 | Recognition Rather Than Recall | 3 | Cards are useful, but the Ecosystem icon uses a generic fallback and "Beryl-style" requires memory/context. |
| 7 | Flexibility and Efficiency | 3 | Experienced developers get a good API overview card, but no direct HexDocs route from the homepage. |
| 8 | Aesthetic and Minimalist Design | 3 | The page is clean, but repeated tagline/description copy flattens hierarchy. |
| 9 | Error Recovery | 2 | Error handling is a library strength, but the homepage example hides it at the key learning moment. |
| 10 | Help and Documentation | 3 | Strong docs structure; homepage could route more directly to error handling or generated API docs. |
| **Total** | | **29/40** | **Good foundation; fix first-contact copy and examples.** |

#### Anti-Patterns Verdict

**LLM assessment**: This does not read as AI-generated slop. It avoids gradient text, hero metrics, hype copy, glassmorphism, over-rounded cards, and decorative shadow stacks. The strongest anti-slop quality is specificity: the page talks about lifecycle, codecs, Phoenix compatibility, and the four-function API.

The weak tell is deferred copy: `frontmatter.description`, the hero `tagline`, and the Starlight config description are effectively the same sentence. That is not a visual anti-pattern, but it creates a generated-feeling echo across SEO, navigation metadata, and human-facing hero copy.

**Deterministic scan**: Clean. `node .agents/skills/impeccable/scripts/detect.mjs --json website/src/content/docs/index.mdx` returned exit code 0 with `[]` findings.

**Visual overlays**: Not available. Browser automation was unavailable in this session; no overlay injection was attempted.

#### Overall Impression

Aquamarine's docs homepage is calm, credible, and refreshingly free of SaaS theater. The biggest opportunity is to make the first 10 seconds as sharp as the best line on the page: "Four functions: `connect`, `push`, `receive`, `close`." The current hero classifies the library accurately, but it does not yet orient a Phoenix/Gleam developer as quickly as it could.

#### What's Working

1. **The content is compact and useful.** What it is, install, first connection, and next destinations all fit without filler.
2. **The docs IA is sensible.** The card grid maps to real reader needs: getting started, Phoenix/Beryl, ecosystem, and API overview.
3. **The visual identity is disciplined.** The dark navy/aquamarine Starlight theme is coherent and avoids decorative excess.

#### Priority Issues

**[P1] Hero tagline leads with ecosystem jargon.**

**Why it matters**: "Beryl-style" is meaningful inside this ecosystem, but many first-time readers will know Phoenix Channels before they know Beryl. The hero asks them to parse taxonomy before it gives them a familiar anchor.

**Fix**: Lead with the known job and move Beryl into supporting copy. Example direction: "Connect Gleam processes to Phoenix Channels. Four functions, explicit errors, pluggable codecs." Keep the SEO description factual; make the hero human-first.

**Suggested command**: `$impeccable clarify website/src/content/docs/index.mdx`

**[P1] The first code sample hides the explicit error model.**

**Why it matters**: `let assert Ok(channel) = aquamarine.connect(...)` is fine for a tiny taste, but it teaches panic-on-failure at the exact moment the library should be building trust around typed errors and cleanup guarantees.

**Fix**: Either show a short `case` expression with an `Error(error)` arm, or label the assert as a docs-only shortcut and immediately link to error handling. The homepage should make `AquamarineError` visible earlier.

**Suggested command**: `$impeccable harden website/src/content/docs/index.mdx`

**[P2] Description copy repeats across metadata and hero.**

**Why it matters**: SEO description, Starlight description, and hero tagline serve different contexts. Reusing one sentence everywhere makes the page feel less deliberately authored.

**Fix**: Keep metadata keyword-rich; rewrite the hero for comprehension and confidence. The first visible line should not be the same as the browser/search summary.

**Suggested command**: `$impeccable clarify website/src/content/docs/index.mdx`

**[P2] The Ecosystem card icon looks unresolved.**

**Why it matters**: `seti:default` reads like a fallback rather than a chosen symbol, especially beside intentional icons like rocket, puzzle, and open-book.

**Fix**: Choose an icon that communicates map/system/package relationships, or make the card copy carry the full recognition load without a generic icon.

**Suggested command**: `$impeccable polish website/src/content/docs/index.mdx`

**[P2] Install and Quick taste are logically one quick-start unit.**

**Why it matters**: Separate peer H2s make the page hierarchy flatter than the reader journey: understand the library, try it, then navigate deeper.

**Fix**: Merge Install and Quick taste under a single "Quick start" or "First connection" section.

**Suggested command**: `$impeccable layout website/src/content/docs/index.mdx`

#### Persona Red Flags

**Jordan, first-time developer**: The first line uses "Beryl-style" before explanation. Jordan may know Phoenix Channels and Gleam, but not Beryl, so the hero creates avoidable uncertainty.

**Sam, accessibility-dependent user**: The Starlight foundation is a strength, and the logo has alt text. The light-theme accent `#1e8e84` on white is close to the WCAG AA threshold for small text and should be checked in rendered states before relying on it broadly.

**Casey, mobile reader**: The short code sample and Starlight responsive shell are likely okay. The main risk is horizontal code scrolling if the homepage example grows; if the error-handling sample expands, keep it compact.

**Gleam library evaluator**: This persona will notice `let assert` immediately. For a library that advertises typed errors and cleanup behavior, the first sample should demonstrate or acknowledge the production-safe path.

#### Minor Observations

- Sidebar label "Introduction" does not match the page title "Aquamarine"; harmless, but slightly less direct.
- "Quick taste" is more casual than the rest of the precise, expert voice. "First connection" would fit better.
- The homepage links to API overview but not directly to HexDocs; experienced users may want the generated signatures faster.
- The clean detector result is meaningful: no obvious slop-family rule triggers in the source markup.

#### Questions to Consider

1. What would the hero say if it borrowed the specificity of the API card: "Four functions: `connect`, `push`, `receive`, `close`"?
2. Should the homepage make one intentional boundary explicit, such as "push does not wait for replies" or "protocol details live in codecs"?
3. Is Ecosystem more important than Error handling as a homepage card for first-time users?
