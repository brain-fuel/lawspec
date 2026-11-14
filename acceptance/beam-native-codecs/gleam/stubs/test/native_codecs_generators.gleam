// User-owned LawSpec adapter. Implement these functions.

import native_codecs as native_native_codecs
import qcheck

pub fn parcels(
  _child0: qcheck.Generator(a0),
) -> qcheck.Generator(native_native_codecs.Parcel(a0)) {
  panic as "Implement generator for native.codecs::type::Parcel"
}

pub fn positives() -> qcheck.Generator(native_native_codecs.Positive) {
  panic as "Implement generator for native.codecs::type::Positive"
}
