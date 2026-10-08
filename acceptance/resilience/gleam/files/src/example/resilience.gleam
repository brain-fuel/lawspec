// ref:DEC-acceptance-with-mutants
import example/limits/definitions
import gleam/list
import lawspec/data
import lawspec/workflow

@external(erlang, "beam_policy_probe", "exponential")
fn exponential(base: Int, factor: Int, attempt: Int) -> Int
pub fn runtime_exponential_delay(base: Int, factor: Int, attempt: Int) -> Int {
  exponential(base, factor, attempt)
}
@external(erlang, "beam_policy_probe", "linear")
pub fn runtime_linear_delay(base: Int, step: Int, attempt: Int) -> Int
@external(erlang, "beam_policy_probe", "fibonacci")
pub fn runtime_fibonacci_delay(base: Int, attempt: Int) -> Int
@external(erlang, "beam_policy_probe", "split_mix")
pub fn split_mix(seed: Int, count: Int) -> List(Int)
@external(erlang, "beam_policy_probe", "full_jitter")
pub fn full_jitter(seed: Int, delay: Int) -> Int
@external(erlang, "beam_policy_probe", "waits")
fn waits(attempts: Int, accepts: Bool) -> List(Int)
pub fn retried_waits(attempts: Int) -> List(Int) { waits(attempts, True) }
pub fn rejected_waits(attempts: Int) -> List(Int) { waits(attempts, False) }
@external(erlang, "beam_policy_probe", "monotonic_millis")
fn monotonic_millis() -> Int
@external(erlang, "beam_policy_probe", "with_quotes")
fn with_quotes(body: fn() -> a) -> a
@external(erlang, "beam_policy_probe", "current")
fn current() -> workflow.Runtime

pub fn limited_at(times: List(Int)) -> List(Bool) {
  use runtime <- workflow.with_virtual(0)
  list.map(times, fn(time) {
    workflow.set_time(runtime, time)
    case definitions.limited(data.Ticket(0)) { Ok(_) -> True Error(_) -> False }
  })
}
pub fn compensations_for(n: Int) -> List(String) {
  use runtime <- workflow.with_virtual(0)
  let _ = definitions.book(data.Ticket(n))
  workflow.trace(runtime)
  |> list.filter(fn(event) { event.kind == "compensate" })
  |> list.map(fn(event) { event.stage })
}
pub fn quote_timed_out(n: Int) -> Bool {
  use _ <- workflow.with_real(0)
  definitions.quoted(data.Ticket(n)) == Error(data.QuotedErrorQuotedTimedOut)
}
pub fn quote_hedged(n: Int) -> Bool {
  use <- with_quotes()
  let started = monotonic_millis()
  let result = definitions.hedged(data.Ticket(n))
  let quick = monotonic_millis() - started < 400
  let hedged = list.any(workflow.trace(current()), fn(event) { event.kind == "hedge" })
  result == Ok(data.Ticket(n)) && quick && { n != -2 || hedged }
}
