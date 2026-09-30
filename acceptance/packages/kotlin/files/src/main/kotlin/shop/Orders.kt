// User-owned LawSpec adapter.
package shop

import lawspec.data.Line
import lawspec.data.Money
import lawspec.data.Quantity
import lawspec.data.ShopDomainCurrency
import lawspec.data.ShopOrdersCurrency

object Orders {
    fun settlement(value0: ShopOrdersCurrency): ShopDomainCurrency =
        if (value0 is ShopOrdersCurrency.UsdCase) ShopDomainCurrency.UsdCase() else ShopDomainCurrency.EurCase()

    fun lineTotal(value0: Line): Money {
        val line = value0 as Line.LineCase
        val price = line.price as Money.MoneyCase
        val count = (line.quantity as Quantity.QuantityCase).value.toLong()
        return Money.MoneyCase(price.currency, minOf(price.cents * count, 100000000L))
    }

    fun cheaper(value0: Long, value1: Long): Long = minOf(value0, value1)

    fun roundDown(value0: Long): Long = value0 - value0 % 100
}
