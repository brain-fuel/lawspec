//// ref:REQ-harness-units
import lawspec/data.{type Guard}

@external(erlang, "beam_status_support", "record")
fn record(name: String, value: a) -> a
pub fn ordinary(flag: Bool) -> Bool { record("ordinary", flag) }

@external(erlang, "beam_status_support", "forbidden")
pub fn skipped(n: Int) -> Int
@external(erlang, "beam_status_support", "property_bug")
pub fn property_bug(n: Int) -> Int
@external(erlang, "beam_status_support", "example_bug")
pub fn example_bug(n: Int) -> Int
@external(erlang, "beam_status_support", "finite_bug")
pub fn finite_bug(flag: Bool) -> Bool
@external(erlang, "beam_status_support", "scored_bug")
pub fn scored_bug(n: Int) -> Int
@external(erlang, "beam_status_support", "forbidden")
pub fn open_guard(unit: Nil) -> Guard
@external(erlang, "beam_status_support", "forbidden")
pub fn close_guard(guard: Guard) -> Nil
@external(erlang, "beam_status_support", "forbidden")
pub fn guard_live(guard: Guard) -> Bool
