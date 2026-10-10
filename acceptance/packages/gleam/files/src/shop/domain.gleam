// ref:DEC-acceptance-with-mutants
import lawspec/data
pub fn convert(currency: data.ShopDomainTypeCurrency, money: data.Money) -> data.Money {
  data.Money(currency, money.cents)
}
