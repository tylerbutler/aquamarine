import aquamarine/ref
import gleam/erlang/process
import gleeunit/should

pub fn ref_tests_test() {
  // produces monotonically increasing refs as strings
  let assert Ok(counter) = ref.start()
  ref.next(counter) |> should.equal(Ok("1"))
  ref.next(counter) |> should.equal(Ok("2"))
  ref.next(counter) |> should.equal(Ok("3"))

  // issues independent sequences for separate counters
  let assert Ok(a) = ref.start()
  let assert Ok(b) = ref.start()
  ref.next(a) |> should.equal(Ok("1"))
  ref.next(a) |> should.equal(Ok("2"))
  ref.next(b) |> should.equal(Ok("1"))
  ref.next(a) |> should.equal(Ok("3"))
  ref.next(b) |> should.equal(Ok("2"))

  // can stop a counter without hanging
  let assert Ok(counter) = ref.start()
  ref.next(counter) |> should.equal(Ok("1"))

  ref.stop(counter)
  process.sleep(10)

  // returns an error after the counter stops
  let assert Ok(counter) = ref.start()
  ref.next(counter) |> should.equal(Ok("1"))

  ref.stop(counter)
  process.sleep(10)

  ref.next(counter) |> should.equal(Error(Nil))
}
