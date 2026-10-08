// ref:DEC-tests-cite-requirements ref:DEC-actors-otp-supervision
import lawspec/data
import lawspec/abilities/example/actor_abilities as abilities
import lawspec/actors/example/actor_abilities/counter_actor as counter
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
