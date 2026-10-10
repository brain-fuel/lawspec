//// ref:REQ-harness-units
@external(erlang, "beam_target_support", "record")
fn record(name: String, value: a) -> a

pub fn number(n: Int) -> Int {
  let assert True = n >= 0 && n <= 1000
  record("number", n)
}
pub fn dependent(x: Int, y: Int) -> Int {
  let assert True = x >= 0 && x < 1000 && y > x && y <= 1000
  let _ = record("dependent", [x, y])
  y
}
pub fn wide(n: Int) -> Int { record("wide", n) }
