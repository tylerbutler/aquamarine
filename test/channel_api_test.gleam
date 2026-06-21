import aquamarine
import aquamarine/channel.{type Config, type Handlers}
import aquamarine/codec.{type Incoming}
import aquamarine/error as error
import aquamarine/error.{type AquamarineError}
import aquamarine/phoenix
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleeunit/should

type State {
  State(joined: Bool, messages: Int, errors: Int, closed: Bool)
}

pub fn channel_api_tests_test() {
  let config =
    aquamarine.config(
      host: "127.0.0.1",
      port: 47_891,
      path: "/socket/websocket",
      topic: "test:lobby",
      payload: json.object([]),
      codec: phoenix.codec(),
    )

  let handlers =
    aquamarine.handlers(
      on_joined: on_joined,
      on_message: on_message,
      on_error: on_error,
      on_closed: on_closed,
    )

  let assert Config(host, port, path, topic, payload, codec) = config
  host |> should.equal("127.0.0.1")
  port |> should.equal(47_891)
  path |> should.equal("/socket/websocket")
  topic |> should.equal("test:lobby")
  payload |> should.equal(json.object([]))
  codec.join_event |> should.equal(phoenix.codec().join_event)

  let assert Handlers(
    on_joined: joined,
    on_message: message,
    on_error: errored,
    on_closed: closed,
  ) = handlers

  let assert Ok(dynamic_payload) = json.parse("{}", decode.dynamic)
  let initial = State(False, 0, 0, False)

  joined(initial, dynamic_payload)
  |> should.equal(aquamarine.continue(State(True, 0, 0, False)))

  message(
    initial,
    Incoming(
      join_ref: None,
      ref: None,
      topic: "test:lobby",
      event: "tick",
      payload: dynamic_payload,
    ),
  )
  |> should.equal(aquamarine.continue(State(False, 1, 0, False)))

  errored(initial, error.ChannelClosed)
  |> should.equal(aquamarine.continue(State(False, 0, 1, False)))

  closed(initial)
  |> should.equal(aquamarine.continue(State(False, 0, 0, True)))

  let _ = aquamarine.continue(initial)
  let _ = aquamarine.stop()
  let _ = aquamarine.connect(config, handlers, initial)
}

fn on_joined(state: State, _payload: Dynamic) {
  aquamarine.continue(State(..state, joined: True))
}

fn on_message(state: State, _incoming: Incoming) {
  aquamarine.continue(State(..state, messages: state.messages + 1))
}

fn on_error(state: State, _error: AquamarineError) {
  aquamarine.continue(State(..state, errors: state.errors + 1))
}

fn on_closed(state: State) {
  aquamarine.continue(State(..state, closed: True))
}
