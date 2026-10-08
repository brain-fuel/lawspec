// ref:DEC-acceptance-with-mutants
import gleam/string
pub fn price(sku: String) -> Int { price_of(sku) }
pub fn stock(sku: String) -> Int { string.length(sku) }
pub fn quote(sku: String) -> Int { price_of(sku) }
fn price_of(sku: String) -> Int {
  case sku {
    "free" -> 0
    _ -> string.length(sku) % 100
  }
}
