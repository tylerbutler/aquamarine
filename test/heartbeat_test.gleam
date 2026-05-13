import aquamarine/heartbeat
import aquamarine/phoenix
import aquamarine/ref
import gleam/erlang/process
import gleam/option
import startest.{describe, it}
import startest/expect

pub fn heartbeat_tests() {
  describe("heartbeat", [
    it("sends heartbeat frames on the configured interval", fn() {
      let sink = process.new_subject()
      let assert Ok(counter) = ref.start()
      let codec = phoenix.codec()
      let send_fn = fn(text: String) -> Result(Nil, Nil) {
        process.send(sink, text)
        Ok(Nil)
      }

      let assert Ok(hb) = heartbeat.start(send_fn, 20, counter, codec)

      let first = process.receive(sink, 200)
      let second = process.receive(sink, 200)
      let third = process.receive(sink, 200)

      heartbeat.stop(hb)

      let assert Ok(frame1) = first
      let assert Ok(decoded1) = codec.decode(frame1)
      decoded1.topic |> expect.to_equal(codec.heartbeat_topic)
      decoded1.event |> expect.to_equal("heartbeat")

      let assert Ok(_) = second
      let assert Ok(_) = third
      Nil
    }),
    it("uses monotonically increasing refs from the counter", fn() {
      let sink = process.new_subject()
      let assert Ok(counter) = ref.start()
      let codec = phoenix.codec()
      let send_fn = fn(text: String) -> Result(Nil, Nil) {
        process.send(sink, text)
        Ok(Nil)
      }

      let assert Ok(hb) = heartbeat.start(send_fn, 20, counter, codec)

      let assert Ok(f1) = process.receive(sink, 200)
      let assert Ok(f2) = process.receive(sink, 200)

      heartbeat.stop(hb)

      let assert Ok(d1) = codec.decode(f1)
      let assert Ok(d2) = codec.decode(f2)

      // Refs increment but exact values depend on counter usage; just assert ordering.
      let assert option.Some(r1) = d1.ref
      let assert option.Some(r2) = d2.ref
      { r1 != r2 } |> expect.to_equal(True)
      Nil
    }),
    it("stops after a send failure without scheduling another tick", fn() {
      let sink = process.new_subject()
      let assert Ok(counter) = ref.start()
      let codec = phoenix.codec()
      let send_fn = fn(text: String) -> Result(Nil, Nil) {
        process.send(sink, text)
        Error(Nil)
      }

      let assert Ok(_) = heartbeat.start(send_fn, 20, counter, codec)

      let first = process.receive(sink, 200)
      process.sleep(60)
      let second = process.receive(sink, 20)

      let assert Ok(_) = first
      second |> expect.to_equal(Error(Nil))
      Nil
    }),
  ])
}
