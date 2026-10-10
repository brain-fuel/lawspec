//// ref:REQ-harness-units
import lawspec/data.{type Parcel}

@external(erlang, "beam_strategy_support", "record")
fn record(label: String, value: a) -> a

pub fn numbers(n: Int) -> Int { record("numbers", n) }
pub fn parcels(p: Parcel) -> Parcel { record("parcels", p) }
pub fn dependent(x: Int, y: Int) -> Int {
  let _ = record("dependent", #(x, y))
  y
}
pub fn defaults(n: Int) -> Int { record("defaults", n) }
pub fn wide(n: Int) -> Int { record("wide", n) }
pub fn finite(flag: Bool) -> Bool { record("finite", flag) }
pub fn shadowed(n: Int) -> Int { record("shadowed", n) }
