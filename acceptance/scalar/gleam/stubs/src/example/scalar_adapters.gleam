// User-owned LawSpec adapter. Implement these functions.

import lawspec/types

pub fn echo_char(_argument0: Int) -> Int {
  panic as "Not implemented: example.scalar_adapters::echoChar"
}

pub fn echo_code_point(_argument0: Int) -> Int {
  panic as "Not implemented: example.scalar_adapters::echoCodePoint"
}

pub fn echo_code_unit(_argument0: Int) -> Int {
  panic as "Not implemented: example.scalar_adapters::echoCodeUnit"
}

pub fn echo_bytes(_argument0: BitArray) -> BitArray {
  panic as "Not implemented: example.scalar_adapters::echoBytes"
}

pub fn echo_complex(_argument0: types.Complex64) -> types.Complex64 {
  panic as "Not implemented: example.scalar_adapters::echoComplex"
}

pub fn successor(_argument0: Int) -> Int {
  panic as "Not implemented: example.scalar_adapters::successor"
}

pub fn narrow(_argument0: Int) -> Int {
  panic as "Not implemented: example.scalar_adapters::narrow"
}

pub fn add_decimal(_argument0: types.Decimal, _argument1: types.Decimal) -> types.Decimal {
  panic as "Not implemented: example.scalar_adapters::addDecimal"
}

pub fn same_symbol(_argument0: types.Symbol, _argument1: types.Symbol) -> Bool {
  panic as "Not implemented: example.scalar_adapters::sameSymbol"
}

pub fn echo_raw(_argument0: List(Int)) -> List(Int) {
  panic as "Not implemented: example.scalar_adapters::echoRaw"
}

pub fn echo_presence(
  _argument0: types.Optional(types.Nullable(Int))
) -> types.Optional(types.Nullable(Int)) {
  panic as "Not implemented: example.scalar_adapters::echoPresence"
}

pub fn finish(_argument0: Nil) -> Nil {
  panic as "Not implemented: example.scalar_adapters::finish"
}

pub fn preserve_big(_argument0: Int) -> Int {
  panic as "Not implemented: example.scalar_adapters::preserveBig"
}

pub fn machine_echo(_argument0: Int) -> Int {
  panic as "Not implemented: example.scalar_adapters::machineEcho"
}
