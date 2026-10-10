//// ref:REQ-harness-units
@external(erlang, "beam_repetition_support", "record")
fn record(name: String, value: a) -> a

@external(erlang, "beam_repetition_support", "transient")
fn transient_call() -> Bool

pub fn number(n: Int) -> Int { record("number", n) }
pub fn finite(flag: Bool) -> Bool { record("finite", flag) }
pub fn transient(_unit: Nil) -> Bool { transient_call() }
pub fn peak(n: Int) -> Int { record("peak", n) }
