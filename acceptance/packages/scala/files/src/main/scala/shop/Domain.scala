// User-owned LawSpec adapter.
package shop

import lawspec.data.Money
import lawspec.data.ShopDomainCurrency

object Domain {
  // One-to-one rates keep the example exact.
  def convert(value0: ShopDomainCurrency, value1: Money): Money =
    Money(value0, value1.cents)
}
