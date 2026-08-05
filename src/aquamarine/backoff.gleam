//// Reconnect backoff schedule.
////
//// Capped exponential growth with jitter, in the spirit of the Phoenix JS
//// client: retry quickly at first, then back off, then keep trying at a fixed
//// ceiling for as long as the caller wants.
////
//// The schedule is a pure function of the attempt number, and the jitter is a
//// function you can replace. Both exist so a test can assert the delays
//// without ever sleeping for real.

import gleam/int
import gleam/option.{type Option, None, Some}

pub opaque type Backoff {
  Backoff(
    initial_ms: Int,
    max_ms: Int,
    /// Growth per attempt, in percent. 200 doubles.
    multiplier: Int,
    jitter: fn(Int) -> Int,
    /// `None` retries forever, which is the usual choice for a client.
    max_attempts: Option(Int),
  )
}

/// The default schedule: 1s, 2s, 4s, 8s, then 10s forever, each with up to
/// 20% jitter subtracted so a fleet of clients does not reconnect in lockstep.
pub fn default() -> Backoff {
  Backoff(
    initial_ms: 1000,
    max_ms: 10_000,
    multiplier: 200,
    jitter: subtract_up_to_20_percent,
    max_attempts: None,
  )
}

/// Delay before the first retry.
pub fn with_initial_ms(backoff: Backoff, ms: Int) -> Backoff {
  Backoff(..backoff, initial_ms: ms)
}

/// Ceiling the delay grows to and stays at.
pub fn with_max_ms(backoff: Backoff, ms: Int) -> Backoff {
  Backoff(..backoff, max_ms: ms)
}

/// Growth per attempt in percent; 200 doubles, 150 is gentler.
pub fn with_multiplier(backoff: Backoff, percent: Int) -> Backoff {
  Backoff(..backoff, multiplier: percent)
}

/// Replace the jitter function.
///
/// Pass `fn(ms) { ms }` for an exactly predictable schedule — which is what
/// makes the delays assertable in a test.
pub fn with_jitter(backoff: Backoff, jitter: fn(Int) -> Int) -> Backoff {
  Backoff(..backoff, jitter: jitter)
}

/// Give up after this many consecutive failed attempts.
pub fn with_max_attempts(backoff: Backoff, attempts: Int) -> Backoff {
  Backoff(..backoff, max_attempts: Some(attempts))
}

/// Retry forever. The default.
pub fn retrying_forever(backoff: Backoff) -> Backoff {
  Backoff(..backoff, max_attempts: None)
}

/// Whether another attempt is allowed after `attempts` have already failed.
pub fn may_retry(backoff: Backoff, attempts: Int) -> Bool {
  case backoff.max_attempts {
    None -> True
    Some(limit) -> attempts < limit
  }
}

/// How long to wait before attempt `attempt`, counting from 1.
///
/// Growth is capped at `max_ms` *before* jitter, so jitter never pushes a
/// delay above the ceiling.
pub fn delay_ms(backoff: Backoff, attempt: Int) -> Int {
  backoff.jitter(int.min(grow(backoff, attempt), backoff.max_ms))
}

fn grow(backoff: Backoff, attempt: Int) -> Int {
  case attempt <= 1 {
    True -> backoff.initial_ms
    False ->
      // Stop multiplying once past the ceiling; nothing needs a delay of
      // 2^30 milliseconds, and the intermediate would overflow into
      // meaninglessness.
      case grow(backoff, attempt - 1) {
        previous if previous >= backoff.max_ms -> backoff.max_ms
        previous -> previous * backoff.multiplier / 100
      }
  }
}

fn subtract_up_to_20_percent(ms: Int) -> Int {
  case ms / 5 {
    0 -> ms
    spread -> ms - int.random(spread)
  }
}
