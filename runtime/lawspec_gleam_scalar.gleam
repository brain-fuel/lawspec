//// Typed operations on the portable exact and IEEE scalar values.
//// ref:DEC-portable-exact-arithmetic ref:DEC-idiomatic-generated-types

import lawspec/types
import gleam/option

@external(erlang, "lawspec_beam_scalar", "ratio")
pub fn rational(numerator: Int, denominator: Int) -> types.Rational

@external(erlang, "lawspec_beam_scalar", "exact")
pub fn rational_parts(value: types.Rational) -> #(Int, Int)

@external(erlang, "lawspec_beam_scalar", "decimal")
pub fn decimal(coefficient: Int, exponent: Int) -> types.Decimal

@external(erlang, "lawspec_beam_gleam", "decimal_parts")
pub fn decimal_parts(value: types.Decimal) -> #(Int, Int)

@external(erlang, "lawspec_beam_gleam", "float32_from_bits")
pub fn float32_from_bits(bits: Int) -> types.Float32

@external(erlang, "lawspec_beam_gleam", "float_bits")
pub fn float32_bits(value: types.Float32) -> Int

@external(erlang, "lawspec_beam_gleam", "float32_from_native")
pub fn float32_from_float(value: Float) -> types.Float32

@external(erlang, "lawspec_beam_gleam", "float_to_native")
pub fn float32_to_float(value: types.Float32) -> Result(Float, String)

@external(erlang, "lawspec_beam_gleam", "scalar_compare")
pub fn float32_compare(a: types.Float32, b: types.Float32) -> option.Option(Int)

@external(erlang, "lawspec_beam_gleam", "float64_from_bits")
pub fn float64_from_bits(bits: Int) -> types.Float64

@external(erlang, "lawspec_beam_gleam", "float_bits")
pub fn float64_bits(value: types.Float64) -> Int

@external(erlang, "lawspec_beam_gleam", "float64_from_native")
pub fn float64_from_float(value: Float) -> types.Float64

@external(erlang, "lawspec_beam_gleam", "float_to_native")
pub fn float64_to_float(value: types.Float64) -> Result(Float, String)

@external(erlang, "lawspec_beam_gleam", "scalar_compare")
pub fn float64_compare(a: types.Float64, b: types.Float64) -> option.Option(Int)

@external(erlang, "lawspec_beam_gleam", "complex64")
pub fn complex64(real: types.Float32, imaginary: types.Float32) -> types.Complex64

@external(erlang, "lawspec_beam_gleam", "complex_parts")
pub fn complex64_parts(value: types.Complex64) -> #(types.Float32, types.Float32)

@external(erlang, "lawspec_beam_gleam", "complex128")
pub fn complex128(real: types.Float64, imaginary: types.Float64) -> types.Complex128

@external(erlang, "lawspec_beam_gleam", "complex_parts")
pub fn complex128_parts(value: types.Complex128) -> #(types.Float64, types.Float64)

@external(erlang, "lawspec_beam_scalar", "new_symbol")
pub fn symbol(description: String) -> types.Symbol

@external(erlang, "lawspec_beam_gleam", "symbol_description")
pub fn symbol_description(value: types.Symbol) -> String

@external(erlang, "lawspec_beam_scalar", "equal")
pub fn symbol_equal(a: types.Symbol, b: types.Symbol) -> Bool

@external(erlang, "lawspec_beam_gleam", "scalar_binary")
fn binary(op: String, kind: String, a: value, b: value) -> value

pub fn rational_add(a: types.Rational, b: types.Rational) -> types.Rational {
  binary("+", "Rational", a, b)
}

pub fn rational_subtract(a: types.Rational, b: types.Rational) -> types.Rational {
  binary("-", "Rational", a, b)
}

pub fn rational_multiply(a: types.Rational, b: types.Rational) -> types.Rational {
  binary("*", "Rational", a, b)
}

pub fn rational_divide(a: types.Rational, b: types.Rational) -> types.Rational {
  binary("/", "Rational", a, b)
}

@external(erlang, "lawspec_beam_scalar", "equal")
pub fn rational_equal(a: types.Rational, b: types.Rational) -> Bool

@external(erlang, "lawspec_beam_scalar", "negate")
pub fn rational_negate(value: types.Rational) -> types.Rational

pub fn decimal_add(a: types.Decimal, b: types.Decimal) -> types.Decimal {
  binary("+", "Decimal", a, b)
}

pub fn decimal_subtract(a: types.Decimal, b: types.Decimal) -> types.Decimal {
  binary("-", "Decimal", a, b)
}

pub fn decimal_multiply(a: types.Decimal, b: types.Decimal) -> types.Decimal {
  binary("*", "Decimal", a, b)
}

@external(erlang, "lawspec_beam_scalar", "equal")
pub fn decimal_equal(a: types.Decimal, b: types.Decimal) -> Bool

@external(erlang, "lawspec_beam_scalar", "negate")
pub fn decimal_negate(value: types.Decimal) -> types.Decimal

pub fn float32_add(a: types.Float32, b: types.Float32) -> types.Float32 {
  binary("+", "Float32", a, b)
}

pub fn float32_subtract(a: types.Float32, b: types.Float32) -> types.Float32 {
  binary("-", "Float32", a, b)
}

pub fn float32_multiply(a: types.Float32, b: types.Float32) -> types.Float32 {
  binary("*", "Float32", a, b)
}

pub fn float32_divide(a: types.Float32, b: types.Float32) -> types.Float32 {
  binary("/", "Float32", a, b)
}

@external(erlang, "lawspec_beam_scalar", "equal")
pub fn float32_equal(a: types.Float32, b: types.Float32) -> Bool

@external(erlang, "lawspec_beam_scalar", "negate")
pub fn float32_negate(value: types.Float32) -> types.Float32

pub fn float64_add(a: types.Float64, b: types.Float64) -> types.Float64 {
  binary("+", "Float64", a, b)
}

pub fn float64_subtract(a: types.Float64, b: types.Float64) -> types.Float64 {
  binary("-", "Float64", a, b)
}

pub fn float64_multiply(a: types.Float64, b: types.Float64) -> types.Float64 {
  binary("*", "Float64", a, b)
}

pub fn float64_divide(a: types.Float64, b: types.Float64) -> types.Float64 {
  binary("/", "Float64", a, b)
}

@external(erlang, "lawspec_beam_scalar", "equal")
pub fn float64_equal(a: types.Float64, b: types.Float64) -> Bool

@external(erlang, "lawspec_beam_scalar", "negate")
pub fn float64_negate(value: types.Float64) -> types.Float64

pub fn complex64_add(a: types.Complex64, b: types.Complex64) -> types.Complex64 {
  binary("+", "Complex64", a, b)
}

pub fn complex64_subtract(a: types.Complex64, b: types.Complex64) -> types.Complex64 {
  binary("-", "Complex64", a, b)
}

pub fn complex64_multiply(a: types.Complex64, b: types.Complex64) -> types.Complex64 {
  binary("*", "Complex64", a, b)
}

pub fn complex64_divide(a: types.Complex64, b: types.Complex64) -> types.Complex64 {
  binary("/", "Complex64", a, b)
}

@external(erlang, "lawspec_beam_scalar", "equal")
pub fn complex64_equal(a: types.Complex64, b: types.Complex64) -> Bool

@external(erlang, "lawspec_beam_scalar", "negate")
pub fn complex64_negate(value: types.Complex64) -> types.Complex64

pub fn complex128_add(a: types.Complex128, b: types.Complex128) -> types.Complex128 {
  binary("+", "Complex128", a, b)
}

pub fn complex128_subtract(a: types.Complex128, b: types.Complex128) -> types.Complex128 {
  binary("-", "Complex128", a, b)
}

pub fn complex128_multiply(a: types.Complex128, b: types.Complex128) -> types.Complex128 {
  binary("*", "Complex128", a, b)
}

pub fn complex128_divide(a: types.Complex128, b: types.Complex128) -> types.Complex128 {
  binary("/", "Complex128", a, b)
}

@external(erlang, "lawspec_beam_scalar", "equal")
pub fn complex128_equal(a: types.Complex128, b: types.Complex128) -> Bool

@external(erlang, "lawspec_beam_scalar", "negate")
pub fn complex128_negate(value: types.Complex128) -> types.Complex128
