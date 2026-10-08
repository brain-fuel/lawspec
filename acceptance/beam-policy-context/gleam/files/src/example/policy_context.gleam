// ref:DEC-acceptance-with-mutants
import example/policy_context/definitions
import gleam/result
@external(erlang, "beam_policy_context_probe", "succeeds")
fn succeeds(value: Int) -> Bool
@external(erlang, "beam_policy_context_probe", "undo")
pub fn undo(value: Int) -> Bool
@external(erlang, "beam_policy_context_probe", "check")
fn check(entries: List(#(String, fn(Int) -> Bool))) -> Bool
pub fn step(n: Int) -> Result(Int, String) {
  case succeeds(n) { True -> Ok(n) False -> Error("retry") }
}
pub fn always_fail(_n: Int) -> Result(Int, String) { Error("stopped") }
pub fn native_probe(_unit: Nil) -> Bool {
  check([
    #("fixed", fn(n) { result.is_ok(definitions.fixed(n)) }),
    #("linear", fn(n) { result.is_ok(definitions.linear(n)) }),
    #("fibonacci", fn(n) { result.is_ok(definitions.fibonacci(n)) }),
    #("custom", fn(n) { result.is_ok(definitions.custom(n)) }),
    #("rejected", fn(n) { result.is_ok(definitions.rejected(n)) }),
    #("cached", fn(n) { result.is_ok(definitions.cached(n)) }),
    #("broken", fn(n) { result.is_ok(definitions.broken(n)) }),
    #("bounded", fn(n) { result.is_ok(definitions.bounded(n)) }),
    #("waiting", fn(n) { result.is_ok(definitions.waiting(n)) }),
    #("compensated", fn(n) { result.is_ok(definitions.compensated(n)) })
  ])
}
