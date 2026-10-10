// ref:DEC-acceptance-with-mutants
import lawspec/data
pub fn settlement(currency: data.ShopOrdersTypeCurrency) -> data.ShopDomainTypeCurrency {
  case currency {
    data.ShopOrdersTypeCurrencyUsd -> data.ShopDomainTypeCurrencyUsd
    data.ShopOrdersTypeCurrencyGbp -> data.ShopDomainTypeCurrencyEur
  }
}
pub fn line_total(line: data.Line) -> data.Money {
  let total = line.price.cents * line.quantity.value
  let capped = case total > 100000000 { True -> 100000000 False -> total }
  data.Money(line.price.currency, capped)
}
pub fn cheaper(a: Int, b: Int) -> Int { case a < b { True -> a False -> b } }
pub fn round_down(value: Int) -> Int { value - value % 100 }
pub fn classify(value: Int) -> data.ShopTaxV2x0x0RatesTypeBand {
  case value {
    value if value <= 0 -> data.ShopTaxV2x0x0RatesTypeBandZero
    value if value < 10000 -> data.ShopTaxV2x0x0RatesTypeBandLow
    _ -> data.ShopTaxV2x0x0RatesTypeBandHigh
  }
}
