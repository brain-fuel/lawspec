// ref:DEC-acceptance-with-mutants
import gleam/int

pub fn shipping_cost(kilograms: Int, kilometres: Int) -> Int {
  kilograms * kilometres + 5 * kilograms
}
pub fn label(parcel: Int) -> String { "parcel " <> int.to_string(parcel) }
