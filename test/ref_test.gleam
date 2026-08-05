import aquamarine/ref
import gleam/erlang/process

pub fn produces_monotonically_increasing_refs_as_strings_test() {
  let assert Ok(counter) = ref.start()
  assert ref.next(counter) == Ok("1")
  assert ref.next(counter) == Ok("2")
  assert ref.next(counter) == Ok("3")
}

pub fn issues_independent_sequences_for_separate_counters_test() {
  let assert Ok(a) = ref.start()
  let assert Ok(b) = ref.start()
  assert ref.next(a) == Ok("1")
  assert ref.next(a) == Ok("2")
  assert ref.next(b) == Ok("1")
  assert ref.next(a) == Ok("3")
  assert ref.next(b) == Ok("2")
}

pub fn can_stop_a_counter_without_hanging_test() {
  let assert Ok(counter) = ref.start()
  assert ref.next(counter) == Ok("1")

  ref.stop(counter)
  process.sleep(10)
}

pub fn returns_an_error_after_the_counter_stops_test() {
  let assert Ok(counter) = ref.start()
  assert ref.next(counter) == Ok("1")

  ref.stop(counter)
  process.sleep(10)

  assert ref.next(counter) == Error(Nil)
}
