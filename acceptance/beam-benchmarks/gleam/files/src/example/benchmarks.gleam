//// ref:REQ-harness-units
import lawspec/abilities/example/benchmarks as abilities

@external(erlang, "beam_benchmark_support", "record")
fn record(name: String, value: a) -> a

pub fn ordinary(n: Int) -> Int { record("ordinary", n) }
pub fn work(n: Int) -> Int { record("sync", n) }
pub fn async_work(n: Int) -> Int { record("async", n) }
pub fn false_value(_u: Nil) -> Bool { record("false", False) }
pub fn meter_handler() -> abilities.Meter {
  abilities.meter(fn(_u) { record("production", 1337) })
}
