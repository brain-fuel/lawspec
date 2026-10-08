import lawspec/data
import native_codecs
import qcheck

pub fn parcels(child: qcheck.Generator(a)) -> qcheck.Generator(native_codecs.Parcel(a)) {
  qcheck.map(child, fn(item) { native_codecs.to_parcel(data.Parcel(item), fn(value) { value }) })
}
pub fn positives() -> qcheck.Generator(native_codecs.Positive) {
  qcheck.map(qcheck.bounded_int(1, 127), fn(value) { native_codecs.to_positive(data.Positive(value)) })
}
