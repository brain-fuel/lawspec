// ref:DEC-tests-cite-requirements ref:DEC-actors-otp-supervision
import lawspec/data
import gleam/option.{Some}
import lawspec/network
import lawspec/abilities/example/actor_abilities as abilities
import lawspec/actors/example/actor_abilities/counter_actor as counter
import lawspec/actors/example/actor_abilities/counter_actor_remote as counter_remote
import lawspec/supervisors/example/actor_abilities/bank_supervisor as bank
import lawspec/supervisors/example/actor_abilities/root_supervisor as root

pub fn factor_handler() -> abilities.Factor { abilities.factor(fn(n) { 2 * n }) }
pub fn restore_handler() -> abilities.Restore { abilities.restore(fn(n) { n + 10 }) }
pub fn open_counter(_unit: Nil) -> data.Counter { data.Counter(0) }
pub fn add(factor: abilities.Factor, state: data.Counter, amount: Int) -> data.Pair(Int, data.Counter) {
  let next = state.value + abilities.factor_adjust(factor, amount)
  data.Pair(next, data.Counter(next))
}
pub fn total(state: data.Counter) -> data.Pair(Int, data.Counter) { data.Pair(state.value, state) }
pub fn clear(_state: data.Counter) -> data.Counter { data.Counter(0) }
pub fn echo_lawspec(state: data.Counter, value: option.Option(List(Int))) -> data.Pair(option.Option(List(Int)), data.Counter) {
  data.Pair(value, state)
}
pub fn reopen(restore: abilities.Restore, state: data.Counter) -> data.Counter {
  data.Counter(abilities.restore_restore(restore, state.value))
}

pub fn native_probe(_unit: Nil) -> Bool {
  use supervisor <- root.with_supervisor(factor_handler(), restore_handler())
  let inner = root.bank(supervisor)
  let actor = bank.counter(inner)
  let assert 14 = counter.add(actor, 7)
  counter.crash(actor)
  let assert 24 = counter.total(actor)
  counter.tell_add(actor, 3)
  let assert 30 = counter.total(actor)
  bank.stop(inner)
  let assert 40 = counter.total(actor)
  True
}

@external(erlang, "beam_remote_probe", "with_nodes")
fn with_nodes(body: fn(network.Node, network.Node) -> a) -> a
@external(erlang, "beam_remote_probe", "stop")
fn stop(node: network.Node) -> Nil

pub fn remote_probe(_unit: Nil) -> Bool {
  use a, b <- with_nodes
  use supervisor <- root.with_supervisor(abilities.factor(fn(n) { 3 * n }), restore_handler())
  let inner = root.bank(supervisor)
  let actor = bank.counter(inner)
  let address = counter.serve(actor, b, "counter")
  let remote = counter_remote.connect(a, address)
  let assert 21 = counter_remote.add(remote, 7)
  let assert 21 = counter_remote.total(remote)
  counter.crash(actor)
  let assert 31 = counter_remote.total(remote)
  bank.stop(inner)
  let assert 41 = counter_remote.total(remote)
  let fast = counter_remote.connect_with_timeout(a, address, 1000)
  let assert Some([0, -7]) = counter_remote.echo_lawspec(fast, Some([0, -7]))
  let Nil = counter_remote.clear(fast)
  let assert 0 = counter_remote.total(remote)
  stop(b)
  counter.total(actor) == 0
}
