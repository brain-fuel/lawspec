// User-owned LawSpec adapter. Implement these functions.

pub fn runtime_exponential_delay(_argument0: Int, _argument1: Int, _argument2: Int) -> Int {
  panic as "Not implemented: example.resilience::runtimeExponentialDelay"
}

pub fn runtime_linear_delay(_argument0: Int, _argument1: Int, _argument2: Int) -> Int {
  panic as "Not implemented: example.resilience::runtimeLinearDelay"
}

pub fn runtime_fibonacci_delay(_argument0: Int, _argument1: Int) -> Int {
  panic as "Not implemented: example.resilience::runtimeFibonacciDelay"
}

pub fn split_mix(_argument0: Int, _argument1: Int) -> List(Int) {
  panic as "Not implemented: example.resilience::splitMix"
}

pub fn full_jitter(_argument0: Int, _argument1: Int) -> Int {
  panic as "Not implemented: example.resilience::fullJitter"
}

pub fn retried_waits(_argument0: Int) -> List(Int) {
  panic as "Not implemented: example.resilience::retriedWaits"
}

pub fn rejected_waits(_argument0: Int) -> List(Int) {
  panic as "Not implemented: example.resilience::rejectedWaits"
}

pub fn limited_at(_argument0: List(Int)) -> List(Bool) {
  panic as "Not implemented: example.resilience::limitedAt"
}

pub fn compensations_for(_argument0: Int) -> List(String) {
  panic as "Not implemented: example.resilience::compensationsFor"
}

pub fn quote_timed_out(_argument0: Int) -> Bool {
  panic as "Not implemented: example.resilience::quoteTimedOut"
}

pub fn quote_hedged(_argument0: Int) -> Bool {
  panic as "Not implemented: example.resilience::quoteHedged"
}
