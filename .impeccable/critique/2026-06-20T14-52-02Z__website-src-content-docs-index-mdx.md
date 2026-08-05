---
target: website
total_score: 32
p0_count: 0
p1_count: 2
timestamp: 2026-06-20T14-52-02Z
slug: website-src-content-docs-index-mdx
---
#### Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 3 | Clear docs path, but no version or stability signal for evaluators. |
| 2 | Match System / Real World | 4 | The hero now leads with Phoenix Channels and concrete API language. |
| 3 | User Control and Freedom | 3 | Hero actions, sidebar, and cards provide exits; section-level paths could be more deliberate. |
| 4 | Consistency and Standards | 3 | Starlight patterns hold; card CTA verbs are slightly uneven. |
| 5 | Error Prevention | 2 | Homepage shows safe `case`, but Getting started still uses `let assert Ok(channel)`. |
| 6 | Recognition Rather Than Recall | 4 | Four main next paths are visible and domain-specific. |
| 7 | Flexibility and Efficiency | 3 | Good overview for evaluators; no direct HexDocs/package/version path for returning users. |
| 8 | Aesthetic and Minimalist Design | 3 | Clean and disciplined; the homepage still carries some template-card rhythm. |
| 9 | Error Recovery | 3 | Error handling is now visible, but `io.debug(error)` is not a recovery pattern. |
| 10 | Help and Documentation | 4 | Homepage, cards, and sidebar form a solid docs entry point. |
| **Total** | | **32/40** | **Good; major first-contact issues fixed, now refine sequencing and trust signals.** |

#### Anti-Patterns Verdict

**LLM assessment**: This still does not read as AI slop. It avoids hero metrics, decorative gradients, glassmorphism, gradient text, over-rounded cards, and hype copy. The new tagline is meaningfully stronger: it gives a specific job, API shape, error posture, and extensibility model.

The remaining soft tell is template fatigue in the card grid. Four same-weight cards with similar action-link rhythm are competent Starlight docs, not broken design, but they are the least distinctive part of the surface.

**Deterministic scan**: Clean. `node .agents/skills/impeccable/scripts/detect.mjs --json website/src/content/docs/index.mdx` returned exit code 0 and `[]` findings.

**Visual overlays**: Not available. Browser visualization was skipped because this environment has browser binaries but no display server (`DISPLAY` and `WAYLAND_DISPLAY` unset), so no reliable user-visible overlay was available.

#### Overall Impression

The homepage improved from "accurate library classification" to a clear evaluator pitch: *Gleam + Phoenix Channels, four functions, explicit errors, pluggable codecs.* The previous P1 issues are largely resolved on the homepage itself. The next quality gap is consistency across the docs journey: the homepage promises explicit errors, while the Getting started guide still teaches `let assert`.

#### What's Working

1. **The tagline is now doing real work.** It is specific, falsifiable, and aligned with the product promise.
2. **The first code sample now models typed failure.** The `case` shape supports the explicit-errors message instead of contradicting it.
3. **The Error handling card makes error posture first-class.** Replacing Ecosystem with Error handling improves the learning path for most evaluators.

#### Priority Issues

**[P1] Getting started contradicts the homepage's explicit-error promise.**

**Why it matters**: The homepage now correctly teaches `case Ok/Error`, but `website/src/content/docs/getting-started.md` still uses `let assert Ok(channel)`. A user who clicks the primary card moves from safe error posture to panic-on-failure copy-paste code.

**Fix**: Align Getting started with the homepage: use a `case` example, or explicitly mark `let assert` as a brevity shortcut and link to Error handling.

**Suggested command**: `$impeccable harden website/src/content/docs/getting-started.md`

**[P1] The homepage mixes evaluation and tutorial mode.**

**Why it matters**: "First connection" includes installation, connection, and error handling. That is useful, but it competes with the Getting started guide and makes the homepage more tutorial-like than evaluator-like.

**Fix**: Decide the homepage's job. If it is evaluation, remove or compress the install command and frame the code as "API shape". If it is first-run onboarding, make Getting started less duplicative.

**Suggested command**: `$impeccable distill website/src/content/docs/index.mdx`

**[P2] Card ordering could better match learning dependency.**

**Why it matters**: Error handling is mandatory for every public operation, while Phoenix/Beryl is a protocol choice. The current order puts Phoenix/Beryl before errors.

**Fix**: Reorder cards to Getting started, Error handling, Phoenix & Beryl, API overview; or make Codecs/Phoenix a paired protocol path after fundamentals.

**Suggested command**: `$impeccable layout website/src/content/docs/index.mdx`

**[P2] No version or stability signal.**

**Why it matters**: Aquamarine appears pre-1.0, and Gleam/BEAM library evaluators care about API churn. The homepage gives no quick answer to "can I bet on this?"

**Fix**: Add a subtle Hex.pm/package version badge or stability note near the hero/actions. Keep it factual, not promotional.

**Suggested command**: `$impeccable polish website/src/content/docs/index.mdx`

**[P2] Pluggable codecs are promised but not surfaced as a homepage path.**

**Why it matters**: The tagline sells pluggable codecs, but the card grid does not link to the Codecs guide. Custom-protocol evaluators have to notice the sidebar.

**Fix**: Add or swap in a Codecs card, or add a compact inline link near the codec paragraph.

**Suggested command**: `$impeccable clarify website/src/content/docs/index.mdx`

#### Persona Red Flags

**Jordan, first-time developer**: The homepage is clearer now, but `phoenix.codec()` and `json.object([])` still appear without inline explanation. Jordan can start, but may not understand which parts are required versus example-specific.

**Sam, accessibility-dependent user**: Starlight is a strong base. The `warning` icon for Error handling should be checked in rendered output; it may imply an error state rather than a guide. Decorative icon accessibility depends on Starlight's rendering.

**Casey, mobile reader**: The 20-line Gleam sample plus install block may push the cards far down the page on narrow viewports. If the homepage is meant for scanning, the code preview should stay compact.

**Gleam library evaluator**: The headline and homepage example now match typed-error expectations. The next trust break is the `let assert` pattern in Getting started.

#### Minor Observations

- The detector stayed clean after the edits.
- `io.debug(error)` is honest but not instructive. A short comment pointing to `AquamarineError` variants would make the example stronger.
- "View on GitHub" is a trust path; a Hex.pm path may be more useful for installation/version confidence.
- The sidebar still includes Ecosystem and Codecs, so the removed Ecosystem card did not remove access.

#### Questions to Consider

1. Should the homepage be an evaluator page or a mini getting-started tutorial?
2. Should the card grid prioritize mandatory fundamentals (`Getting started`, `Error handling`) before protocol-specific guides?
3. Is a Hex.pm/version badge appropriate now, or would a pre-1.0 stability note better match the project's current state?
