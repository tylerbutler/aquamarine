# Task 3 Report: Start Stratus and wait for join completion

## Implementation summary
- Replaced the production callback `channel.connect/3` stub with a real Stratus-backed runtime in `src/aquamarine/channel.gleam`.
- `connect` now:
  - builds an HTTP request from `Config`
  - starts Stratus with `new_with_initialiser`, `selecting`, `on_message`, and `on_close`
  - sends a `StartJoin` command through the Stratus subject
  - waits for the matching join reply before returning
  - invokes `handlers.on_joined` with the decoded join `response` payload
  - maps startup failures to Aquamarine transport/channel errors
- Kept `connect_with` plus `src/aquamarine/transport.gleam` as a legacy test-only seam for the existing fake-transport coverage.
- Added minimal callback-channel `push` support because the new production `connect` returns callback channels and the public facade still exposes `push`.
- Removed Gluegun from production dependencies, added Stratus `>= 3.0.0 and < 4.0.0`, and regenerated `manifest.toml`.
- Added `test/support/channel_server.gleam` to run real local Beryl/Mist websocket servers for callback-runtime tests.

## TDD evidence
1. Added callback-runtime tests first in `test/channel_test.gleam`:
   - `connect_waits_for_join_and_calls_on_joined_test`
   - `connect_surfaces_join_rejection_test`
2. Ran the focused test file before implementation:
   - `gleam test -- test/channel_test.gleam`
   - observed expected failure: `Error(InternalError("callback runtime not implemented"))`
3. Implemented the Stratus runtime.
4. Added/expanded real callback integration coverage in `test/integration_test.gleam` for:
   - successful join callback
   - callback `push`
   - join rejection
   - handshake 404 mapping
   - connection-refused startup mapping
5. Re-ran focused tests until green, then full suite.

## Commands run and results
- `gleam test -- test/channel_test.gleam`
  - failed red as expected with `callback runtime not implemented`
- `gleam deps download`
  - resolved Stratus and removed Gluegun/Gun/Cowlib from manifest
- `gleam check`
  - passed after runtime/dependency fixes
- `gleam test -- --test-name-filter='integration_tests_test|connect_'`
  - passed after callback push + startup mapping fixes
- `gleam format src test && gleam test`
  - passed: `9 passed, no failures`

## Files changed
- `gleam.toml`
- `manifest.toml`
- `src/aquamarine/channel.gleam`
- `src/aquamarine/transport.gleam`
- `test/channel_test.gleam`
- `test/integration_test.gleam`
- `test/support/channel_server.gleam` (new)

## Self-review
- Verified production `connect` no longer uses Gluegun.
- Verified join completion waits for the matching reply before returning.
- Verified `on_joined` receives the join `response` payload rather than the wrapper reply object.
- Verified public `push` still works with the new callback channel shape.
- Ran a code-review pass and fixed the two substantive issues it found:
  - callback `push` was initially unimplemented for the new returned channel type
  - startup transport failures were initially collapsed into `HandshakeFailed`

## Concerns / follow-up
- Callback heartbeats remain deferred by scope. The runtime stores heartbeat-related state but does not start heartbeat scheduling yet because later tasks own that behavior.
- Callback-runtime tests do not yet cover every misbehaving join-startup path (`DecodeFailed`, malformed reply, close-during-join) with a real server. Existing legacy fake-transport tests still cover those mappings on `connect_with`.
