// ref:DEC-tests-cite-requirements ref:DEC-actors-otp-supervision
import lawspec/data
import lawspec/actors
import lawspec/actors/example/actors/account_actor as account
import lawspec/supervisors/example/actors/bank_supervisor as bank

pub fn open_account(_unit: Nil) -> data.Account { data.Account(0) }
pub fn deposit(state: data.Account, amount: Int) -> data.Pair(Int, data.Account) {
  let balance = state.balance + amount
  data.Pair(balance, data.Account(balance))
}
pub fn withdraw_all(state: data.Account) -> data.Pair(Int, data.Account) {
  data.Pair(state.balance, data.Account(0))
}
pub fn balance(state: data.Account) -> data.Pair(Int, data.Account) { data.Pair(state.balance, state) }
pub fn close(_state: data.Account) -> data.Account { data.Account(0) }
pub fn reopen(state: data.Account) -> data.Account { state }

@external(erlang, "lawspec_beam_runtime", "concurrently")
fn concurrently(work: List(fn() -> a)) -> List(a)

pub fn deposit_twice(amount: Int) -> Int {
  use actor <- account.with_actor()
  let _ = concurrently([fn() { account.deposit(actor, amount) }, fn() { account.deposit(actor, amount) }])
  account.balance(actor)
}

pub fn survives_crash(amount: Int) -> Int {
  use supervisor <- bank.with_supervisor()
  let actor = bank.account(supervisor)
  let _ = account.deposit(actor, amount)
  account.crash(actor)
  account.balance(actor)
}

@external(erlang, "beam_actor_api_probe", "with_parent")
fn with_parent(spec: actors.ChildSpec, body: fn(actors.Process) -> a) -> a

@external(erlang, "beam_actor_api_probe", "child")
fn child(parent: actors.Process) -> actors.Process

@external(erlang, "beam_actor_api_probe", "round_trip")
fn round_trip(actor: account.AccountActor) -> account.AccountActor

@external(erlang, "beam_actor_api_probe", "is_nil")
fn is_nil(value: Nil) -> Bool

pub fn native_probe(_unit: Nil) -> Bool {
  use parent <- with_parent(bank.child_spec())
  let supervisor = bank.from_process(child(parent))
  let actor = bank.account(supervisor)
  let assert True = actor == round_trip(actor)
  let assert True = is_nil(account.monitor(actor, actors.self()))
  let old = account.worker_pid(actor)
  let assert 5 = account.deposit(actor, 5)
  let assert True = is_nil(account.tell_deposit(actor, 3))
  let assert 8 = account.balance(actor)
  let assert True = is_nil(account.crash(actor))
  let assert Ok(actors.Crashed(_)) = actors.receive_event(actor, 1000)
  let assert False = old == account.worker_pid(actor)
  let assert 8 = account.withdraw_all(actor)
  let assert True = is_nil(account.close(actor))
  let assert True = is_nil(account.tell_close(actor))
  let assert 0 = account.balance(actor)
  True
}
