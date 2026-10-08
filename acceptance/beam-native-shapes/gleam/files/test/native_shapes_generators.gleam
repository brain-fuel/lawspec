import native_shapes
import qcheck

pub fn boxes(child: qcheck.Generator(a)) -> qcheck.Generator(native_shapes.Wrapped(a)) {
  qcheck.map(child, native_shapes.Wrapped)
}
pub fn small_int() -> qcheck.Generator(Int) { qcheck.bounded_int(6, 127) }
pub fn stamps() -> qcheck.Generator(native_shapes.Seal) { panic as "finite type must not call factory" }
