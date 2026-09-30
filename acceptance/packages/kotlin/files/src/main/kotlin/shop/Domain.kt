// User-owned LawSpec adapter.
package shop

import lawspec.data.Money
import lawspec.data.ShopDomainCurrency

object Domain {
    // One-to-one rates keep the example exact.
    fun convert(value0: ShopDomainCurrency, value1: Money): Money =
        Money.MoneyCase(value0, (value1 as Money.MoneyCase).cents)
}
