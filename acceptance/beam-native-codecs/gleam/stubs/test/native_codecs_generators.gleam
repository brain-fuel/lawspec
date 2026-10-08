// User-owned LawSpec adapter. Implement these functions.

import qcheck

import native_codecs as native_0

pub fn parcels(_child0: qcheck.Generator(a0)) -> qcheck.Generator(native_0.Parcel(a0)) {
  panic as "Implement generator for native.codecs::type::Parcel"
}

pub fn positives() -> qcheck.Generator(native_0.Positive) {
  panic as "Implement generator for native.codecs::type::Positive"
}
