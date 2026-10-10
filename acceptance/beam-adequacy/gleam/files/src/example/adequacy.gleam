//// ref:REQ-harness-units
@external(erlang, "beam_adequacy_support", "record")
fn record(name: String, value: a) -> a

pub fn number(n: Int) -> Int { record("number", n) }
pub fn dependent(x: Int, y: Int) -> Int {
  let _ = record("dependent", [x, y])
  y
}
pub fn finite(flag: Bool) -> Bool { record("finite", flag) }
