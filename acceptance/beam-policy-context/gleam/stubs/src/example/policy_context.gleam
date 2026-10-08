// User-owned LawSpec adapter. Implement these functions.

pub fn step(_argument0: Int) -> Result(Int, String) {
  panic as "Not implemented: example.policy_context::step"
}

pub fn undo(_argument0: Int) -> Bool { panic as "Not implemented: example.policy_context::undo" }

pub fn always_fail(_argument0: Int) -> Result(Int, String) {
  panic as "Not implemented: example.policy_context::alwaysFail"
}

pub fn native_probe(_argument0: Nil) -> Bool {
  panic as "Not implemented: example.policy_context::nativeProbe"
}
