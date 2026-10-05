// User-owned LawSpec adapter.
package shop

import lawspec.data.Line
import lawspec.data.Money
import lawspec.data.ShopDomainCurrency
import lawspec.data.ShopOrdersCurrency
import lawspec.data.ShopTaxV2x0x0RatesBand

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

    // Version 2 of shop.tax: no tax on nothing, the high band from 100.00.
    fun classify(value0: Long): ShopTaxV2x0x0RatesBand =
        if (value0 <= 0L) ShopTaxV2x0x0RatesBand.Zero
        else if (value0 < 10000L) ShopTaxV2x0x0RatesBand.Low
        else ShopTaxV2x0x0RatesBand.High
}
