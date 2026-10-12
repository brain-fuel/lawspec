// User-owned LawSpec adapter.
package shop

import lawspec.data.Line
import lawspec.data.Money
import lawspec.data.ShopDomainCurrency
import lawspec.data.ShopOrdersCurrency
import lawspec.data.ShopTaxV2x0x0RatesBand

object Orders {
  def settlement(value0: ShopOrdersCurrency): ShopDomainCurrency =
    value0 match {
      case ShopOrdersCurrency.Usd => ShopDomainCurrency.Usd
      case ShopOrdersCurrency.Gbp => ShopDomainCurrency.Eur
    }

  def lineTotal(value0: Line): Money = {
    val count = value0.quantity.value.toLong
    Money(value0.price.currency, math.min(value0.price.cents * count, 100000000L))
  }

  def cheaper(value0: Long, value1: Long): Long = math.min(value0, value1)

  def roundDown(value0: Long): Long = value0 - value0 % 100

  // Version 2 of shop.tax: no tax on nothing, the high band from 100.00.
  def classify(value0: Long): ShopTaxV2x0x0RatesBand =
    if (value0 <= 0L) ShopTaxV2x0x0RatesBand.Zero
    else if (value0 < 10000L) ShopTaxV2x0x0RatesBand.Low
    else ShopTaxV2x0x0RatesBand.High
}
