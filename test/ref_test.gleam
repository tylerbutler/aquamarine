import aquamarine/ref
import gleam/erlang/process
import startest.{describe, it}
import startest/expect

pub fn ref_tests() {
  describe("ref", [
    it("produces monotonically increasing refs as strings", fn() {
      let assert Ok(counter) = ref.start()
      ref.next(counter) |> expect.to_equal(Ok("1"))
      ref.next(counter) |> expect.to_equal(Ok("2"))
      ref.next(counter) |> expect.to_equal(Ok("3"))
    }),
    it("issues independent sequences for separate counters", fn() {
      let assert Ok(a) = ref.start()
      let assert Ok(b) = ref.start()
      ref.next(a) |> expect.to_equal(Ok("1"))
      ref.next(a) |> expect.to_equal(Ok("2"))
      ref.next(b) |> expect.to_equal(Ok("1"))
      ref.next(a) |> expect.to_equal(Ok("3"))
      ref.next(b) |> expect.to_equal(Ok("2"))
    }),
    it("can stop a counter without hanging", fn() {
      let assert Ok(counter) = ref.start()
      ref.next(counter) |> expect.to_equal(Ok("1"))

      ref.stop(counter)
      process.sleep(10)

      Nil
    }),
    it("returns an error after the counter stops", fn() {
      let assert Ok(counter) = ref.start()
      ref.next(counter) |> expect.to_equal(Ok("1"))

      ref.stop(counter)
      process.sleep(10)

      ref.next(counter) |> expect.to_equal(Error(Nil))
    }),
  ])
}
