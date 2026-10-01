// User-owned LawSpec adapter.
package shop

import lawspec.data.Line
import lawspec.data.Money
import lawspec.data.ShopDomainCurrency
import lawspec.data.ShopOrdersCurrency

object Orders {
    fun settlement(value0: ShopOrdersCurrency): ShopDomainCurrency =
        when (value0) {
            ShopOrdersCurrency.Usd -> ShopDomainCurrency.Usd
            ShopOrdersCurrency.Gbp -> ShopDomainCurrency.Eur
        }

    fun lineTotal(value0: Line): Money {
        val count = value0.quantity.value.toLong()
        return Money(value0.price.currency, minOf(value0.price.cents * count, 100000000L))
    }

    fun cheaper(value0: Long, value1: Long): Long = minOf(value0, value1)

    fun roundDown(value0: Long): Long = value0 - value0 % 100
}
