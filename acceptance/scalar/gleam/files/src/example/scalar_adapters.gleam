// Native Gleam adapters exercise the checked BEAM scalar bridge.
// ref:DEC-acceptance-with-mutants
import lawspec/types
import lawspec/scalar

pub fn echo_char(value: Int) -> Int { value }
pub fn echo_code_point(value: Int) -> Int { value }
pub fn echo_code_unit(value: Int) -> Int { value }
pub fn echo_bytes(value: BitArray) -> BitArray { value }
pub fn echo_complex(value: types.Complex64) -> types.Complex64 { value }
pub fn successor(value: Int) -> Int { value + 1 }
pub fn narrow(value: Int) -> Int { value }
pub fn add_decimal(a: types.Decimal, b: types.Decimal) -> types.Decimal { scalar.decimal_add(a, b) }
pub fn same_symbol(a: types.Symbol, b: types.Symbol) -> Bool { scalar.symbol_equal(a, b) }
pub fn echo_raw(value: List(Int)) -> List(Int) { value }
pub fn echo_presence(value: types.Optional(types.Nullable(Int))) -> types.Optional(types.Nullable(Int)) { value }
pub fn finish(_value: Nil) -> Nil { Nil }
pub fn preserve_big(value: Int) -> Int { value }
pub fn machine_echo(value: Int) -> Int { value }
