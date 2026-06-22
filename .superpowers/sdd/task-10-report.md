Status: done

Changed:
- README quick start now uses `config`, `handlers`, `continue`, `connect(config, handlers, initial_state)`, and Stratus language.
- Website docs now describe callback-driven channel flow, Stratus runtime ownership, and the current transport error categories.
- AGENTS.md now reflects the Stratus-backed runtime and Gleeunit test stack.

Checks:
- Stale docs search clean for `Gluegun`, `receive(`, `blocking receive`, `process ownership`, `transport is fixed`, `fake_transport`, and `Startest`.
- Attempted website build with `pnpm build` in `website/`.

Concerns:
- `pnpm build` failed because `astro-mermaid` could not be resolved from `astro.config.mjs`.
- No code tests were run; this task only updated documentation and repository instructions.

Task 10 notes:
- Updated website docs for actor-owned channels, `aquamarine.stop()`, and current heartbeat/ref behavior.
- Added `InternalError` coverage to error-handling docs and corrected stale `stop(state)` examples.
- Stale-docs search is now clean for the targeted public docs strings; remaining `receive(` hits are legitimate `process.receive` code examples.

Task 10 follow-up:
- Reworked the Phoenix and codecs guides to use `config`, `handlers`, `connect(config, handlers, initial_state)`, `push`, and `close`.
- Aligned AGENTS and the getting-started/channel docs with the Stratus-owned callback flow and heartbeat scheduling inside the channel actor.
- Removed stale non-code `receive` wording from the public docs sweep; remaining `process.receive` uses are runtime examples, not API guidance.
