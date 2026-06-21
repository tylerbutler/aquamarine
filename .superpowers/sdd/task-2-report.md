## What I implemented
- Added the new callback API surface in `aquamarine/channel` and `aquamarine`:
  - `Config`, `Handlers(state)`, `Next(state)`
  - `config`, `handlers`, `continue`, `stop`
  - callback-style `connect(config, handlers, initial_state)`
- Kept the legacy transport path intact for the current suite.
- Added `test/channel_api_test.gleam` and exercised it from `test/channel_test.gleam`.

## Tests and results
- `gleam format --check src test` ✅
- `gleam test` ✅ (`34` tests passed)

## TDD RED / GREEN evidence
- Initial focused run on the new test file did not discover it in the runner, so the API checks were wired into an existing test module to ensure they execute.
- GREEN: after the source/API changes, the full suite passed.

## Files changed
- `src/aquamarine/channel.gleam`
- `src/aquamarine.gleam`
- `test/channel_api_test.gleam`
- `test/channel_test.gleam`

## Self-review findings
- The callback API is now typed and constructible.
- The new callback `connect` is still a stub; no Stratus runtime behavior was added.
- Legacy `receive` remains for now so the current suite stays green.

## Concerns
- Standalone discovery of the new test module did not work in this setup, so it is invoked from `channel_test`.
- Task 9 still needs the remaining `receive` cleanup and runtime migration.
