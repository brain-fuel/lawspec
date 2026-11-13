// User-owned LawSpec adapter. Implement these functions.

pub fn runtime_exponential_delay(
  _integer_1: Int,
  _integer_2: Int,
  _integer_3: Int,
) -> Int {
  panic as "Not implemented: example.resilience::runtimeExponentialDelay"
}

pub fn runtime_linear_delay(
  _integer_1: Int,
  _integer_2: Int,
  _integer_3: Int,
) -> Int {
  panic as "Not implemented: example.resilience::runtimeLinearDelay"
}

pub fn runtime_fibonacci_delay(_integer_1: Int, _integer_2: Int) -> Int {
  panic as "Not implemented: example.resilience::runtimeFibonacciDelay"
}

pub fn split_mix(_uint64_1: Int, _int32_1: Int) -> List(Int) {
  panic as "Not implemented: example.resilience::splitMix"
}

pub fn full_jitter(_uint64_1: Int, _integer_1: Int) -> Int {
  panic as "Not implemented: example.resilience::fullJitter"
}

pub fn retried_waits(_int32_1: Int) -> List(Int) {
  panic as "Not implemented: example.resilience::retriedWaits"
}

pub fn rejected_waits(_int32_1: Int) -> List(Int) {
  panic as "Not implemented: example.resilience::rejectedWaits"
}

pub fn limited_at(_list_1: List(Int)) -> List(Bool) {
  panic as "Not implemented: example.resilience::limitedAt"
}

pub fn compensations_for(_int64_1: Int) -> List(String) {
  panic as "Not implemented: example.resilience::compensationsFor"
}

pub fn quote_timed_out(_int64_1: Int) -> Bool {
  panic as "Not implemented: example.resilience::quoteTimedOut"
}

pub fn quote_hedged(_int64_1: Int) -> Bool {
  panic as "Not implemented: example.resilience::quoteHedged"
}
