// ref:DEC-portable-exact-arithmetic ref:DEC-acceptance-with-mutants
import lawspec/scalar
import gleam/option
import gleam/result

pub fn exact_arithmetic_api_test() {
  let sum = scalar.decimal_add(scalar.decimal(1, -1), scalar.decimal(2, -1))
  assert scalar.decimal_equal(sum, scalar.decimal(3, -1))
  let half = scalar.rational(2, 4)
  assert scalar.rational_parts(half) == #(1, 2)
}

pub fn ieee_bits_and_non_finite_values_api_test() {
  let negative_zero = scalar.float64_from_bits(9223372036854775808)
  let assert Ok(native) = scalar.float64_to_float(negative_zero)
  assert scalar.float64_bits(scalar.float64_from_float(native)) == 9223372036854775808
  let nan = scalar.float32_from_bits(2143289344)
  assert !scalar.float32_equal(nan, nan)
  assert scalar.float32_compare(nan, nan) == option.None
  assert result.is_error(scalar.float32_to_float(nan))
}

pub fn symbol_identity_api_test() {
  let a = scalar.symbol("same")
  let b = scalar.symbol("same")
  assert scalar.symbol_equal(a, a)
  assert !scalar.symbol_equal(a, b)
  assert scalar.symbol_description(a) == "same"
}
