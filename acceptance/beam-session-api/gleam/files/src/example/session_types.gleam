// ref:DEC-tests-cite-requirements ref:DEC-sessions-by-construction
import gleam/option.{Some}
import lawspec/scalar
import lawspec/sessions
import lawspec/sessions/example/session_types/exchange
import lawspec/sessions/example/session_types/symbols
import lawspec/sessions/example/session_types/empty
import lawspec/sessions/example/session_types/answer
import lawspec/sessions/example/session_types/passing
import lawspec/network

@external(erlang, "beam_session_probe", "with_nodes")
fn with_nodes(body: fn(network.Node, network.Node, network.Node, network.Node) -> a) -> a
@external(erlang, "beam_session_probe", "stop")
fn stop(node: network.Node) -> Nil

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

pub fn network_probe(_unit: Nil) -> Bool {
  use a, b, c, d <- with_nodes
  let first = answer.listen(a, "answer")
  let client = answer.dial(c, answer.address(first))
  let client_next = answer.second_send_0(client, 23)
  let on_b = pass(first, a, b, "to-b")
  let on_d = pass(on_b, b, d, "to-d")
  stop(a)
  stop(b)
  let #(x, reply) = answer.first_receive_0(on_d)
  let assert 23 = x
  let _done = answer.first_send_1(reply, 46)
  let #(total, _) = answer.second_receive_1(client_next)
  let assert 46 = total
  let sending = exchange.listen(c, "data")
  let receiving = exchange.dial(d, exchange.address(sending))
  let e1 = exchange.first_send_0(sending, Some([0, -7, 2_147_483_647]))
  let #(value, e2) = exchange.second_receive_0(receiving)
  let assert Some([0, -7, 2_147_483_647]) = value
  let _done = exchange.second_send_1(e2, Nil)
  let #(Nil, _) = exchange.first_receive_1(e1)
  use local, peer <- answer.with_pair
  let remote = pass(local, c, d, "relay")
  let peer_next = answer.second_send_0(peer, 42)
  let #(x, remote_reply) = answer.first_receive_0(remote)
  let assert 42 = x
  let _done = answer.first_send_1(remote_reply, 84)
  let #(total, _) = answer.second_receive_1(peer_next)
  total == 84
}
fn pass(channel_end: answer.First0, a: network.Node, b: network.Node, name: String) -> answer.First0 {
  let giving = passing.listen(a, name)
  let taking = passing.dial(b, passing.address(giving))
  let _done = passing.first_send_0(giving, channel_end)
  let #(moved, _) = passing.second_receive_0(taking)
  moved
}
