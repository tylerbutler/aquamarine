# Task 6 Report

## Status
- Fixed heartbeat scheduling after join in the Stratus channel runtime.

## Changes
- Schedule runtime heartbeats through the Stratus actor subject (`self_subject`).
- Remove the partial attempt's extra heartbeat selector path.
- Update the heartbeat test to use a non-reserved event name so Beryl routes it through the channel handler.

## Tests
- `gleam format src test`
- `gleam test -- --test-name-filter=runtime_heartbeat_schedules_after_join`
- `gleam test`

## Concerns
- None.
