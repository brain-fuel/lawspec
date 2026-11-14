// User-owned LawSpec adapter. Implement these functions.

import native_shapes as native_native_shapes
import qcheck

pub fn boxes(
  _child0: qcheck.Generator(a0),
) -> qcheck.Generator(native_native_shapes.Wrapped(a0)) {
  panic as "Implement generator for native.shapes::type::Box"
}

pub fn small_int() -> qcheck.Generator(Int) {
  panic as "Implement generator for Int8"
}

pub fn stamps() -> qcheck.Generator(native_native_shapes.Seal) {
  panic as "Implement generator for native.shapes::type::Stamp"
}
