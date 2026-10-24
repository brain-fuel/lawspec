// User-owned LawSpec adapter. Implement these functions.

import lawspec/types

pub fn echo_char(_char: Int) -> Int {
  panic as "Not implemented: example.scalar_adapters::echoChar"
}

pub fn echo_code_point(_code_point: Int) -> Int {
  panic as "Not implemented: example.scalar_adapters::echoCodePoint"
}

pub fn echo_code_unit(_code_unit16: Int) -> Int {
  panic as "Not implemented: example.scalar_adapters::echoCodeUnit"
}

pub fn echo_bytes(_bytes: BitArray) -> BitArray {
  panic as "Not implemented: example.scalar_adapters::echoBytes"
}

pub fn echo_complex(_complex64: types.Complex64) -> types.Complex64 {
  panic as "Not implemented: example.scalar_adapters::echoComplex"
}

pub fn successor(_int8: Int) -> Int {
  panic as "Not implemented: example.scalar_adapters::successor"
}

pub fn narrow(_int8: Int) -> Int {
  panic as "Not implemented: example.scalar_adapters::narrow"
}

pub fn add_decimal(
  _decimal: types.Decimal,
  _decimal_2: types.Decimal,
) -> types.Decimal {
  panic as "Not implemented: example.scalar_adapters::addDecimal"
}

pub fn same_symbol(_symbol: types.Symbol, _symbol_2: types.Symbol) -> Bool {
  panic as "Not implemented: example.scalar_adapters::sameSymbol"
}

pub fn echo_raw(_utf16_text: List(Int)) -> List(Int) {
  panic as "Not implemented: example.scalar_adapters::echoRaw"
}

pub fn echo_presence(
  _optional_nullable_int8: types.Optional(types.Nullable(Int)),
) -> types.Optional(types.Nullable(Int)) {
  panic as "Not implemented: example.scalar_adapters::echoPresence"
}

pub fn finish(_unit: Nil) -> Nil {
  panic as "Not implemented: example.scalar_adapters::finish"
}

pub fn preserve_big(_u_int64: Int) -> Int {
  panic as "Not implemented: example.scalar_adapters::preserveBig"
}

pub fn machine_echo(_int_size: Int) -> Int {
  panic as "Not implemented: example.scalar_adapters::machineEcho"
}
