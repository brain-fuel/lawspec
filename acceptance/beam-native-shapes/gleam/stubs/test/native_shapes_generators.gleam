// User-owned LawSpec adapter. Implement these functions.

import qcheck

import native_shapes as native_0

pub fn boxes(_child0: qcheck.Generator(a0)) -> qcheck.Generator(native_0.Wrapped(a0)) {
  panic as "Implement generator for native.shapes::type::Box"
}

pub fn small_int() -> qcheck.Generator(Int) { panic as "Implement generator for Int8" }

pub fn stamps() -> qcheck.Generator(native_0.Seal) {
  panic as "Implement generator for native.shapes::type::Stamp"
}
