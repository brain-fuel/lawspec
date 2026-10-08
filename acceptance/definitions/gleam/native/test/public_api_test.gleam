// ref:DEC-total-definitions ref:DEC-acceptance-with-mutants
import example/refined_definitions/definitions as refined
import example/data_types/definitions as data_definitions
import example/total_functions/definitions as total
import lawspec/data
import lawspec/scalar
import gleam/result

pub fn checked_integer_api_test() {
  assert refined.increment(126) == 127
  assert result.is_error(catch_error(fn() { refined.increment(127) }))
  assert result.is_error(catch_error(fn() { refined.increment(128) }))
}

pub fn typed_data_api_test() {
  let pair = data.Pair(first: 2, second: True)
  assert data_definitions.positive_pair(2) == pair
  assert scalar.rational_parts(data_definitions.reciprocal_first(pair)) == #(1, 2)
  assert result.is_error(catch_error(fn() {
    data_definitions.reciprocal_first(data.Pair(first: 0, second: True))
  }))
}

pub fn lazy_guard_api_test() {
  assert total.guarded_narrow(126)
  assert !total.guarded_narrow(127)
}

@external(erlang, "public_api_ffi", "catch_error")
fn catch_error(run: fn() -> a) -> Result(a, Nil)
