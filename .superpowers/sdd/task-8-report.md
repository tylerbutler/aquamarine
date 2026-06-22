# Task 8 Report

- Rewrote `test/integration_test.gleam` into focused callback-driven gleeunit tests.
- Covered join callback, server push callback, client push reply callback, join rejection, and transport startup errors.
- Kept integration coverage off `aquamarine.receive`.

## Verification

- `gleam format src test`
- `gleam test -- --test-name-filter=integration`
- `gleam test`

## Concerns

- `test/support/channel_server.gleam` does not actually stop Mist servers, so the rewritten integration tests use distinct ports per scenario to avoid reuse collisions.

## Fix notes
- Integration tests now use Mist on port 0 and capture the assigned port at startup, avoiding hardcoded per-test ports.
- `channel_server.register_echo/3` now echoes a `body` field when present, so the client-push reply test asserts both `status` and echoed `body`.
- The Mist server helper still exposes `stop/1`, but shutdown is currently a no-op; dynamic ports removed the collision risk without relying on a fragile stop path.
