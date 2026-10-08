// ref:DEC-tests-cite-requirements ref:DEC-sessions-by-construction
import gleam/option.{Some}
import lawspec/scalar
import lawspec/sessions
import lawspec/sessions/example/session_types/exchange
import lawspec/sessions/example/session_types/symbols
import lawspec/sessions/example/session_types/empty

pub fn native_probe(_unit: Nil) -> Bool {
  exchange.with_pair(fn(first, second) {
    let task = exchange.spawn_second(second, fn(channel_end) {
      let #(value, next) = exchange.second_receive_0(channel_end)
      let assert Some([1, 2, 3]) = value
      let _done = exchange.second_send_1(next, Nil)
      Nil
    })
    let next = exchange.first_send_0(first, Some([1, 2, 3]))
    let #(Nil, _) = exchange.first_receive_1(next)
    sessions.join(task)
  })
  symbols.with_pair(fn(first, second) {
    let identity = scalar.symbol("session")
    let _done = symbols.first_send_0(first, identity)
    let #(received, _) = symbols.second_receive_0(second)
    let assert True = scalar.symbol_equal(identity, received)
  })
  empty.with_pair(fn(_, _) { True })
}
