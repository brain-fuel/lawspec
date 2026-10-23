// User-owned LawSpec adapter. Implement these functions.

pub fn step(_int32: Int) -> Result(Int, String) {
  panic as "Not implemented: example.policy_context::step"
}

pub fn undo(_int32: Int) -> Bool {
  panic as "Not implemented: example.policy_context::undo"
}

pub fn always_fail(_int32: Int) -> Result(Int, String) {
  panic as "Not implemented: example.policy_context::alwaysFail"
}

pub fn native_probe(_unit: Nil) -> Bool {
  panic as "Not implemented: example.policy_context::nativeProbe"
}
