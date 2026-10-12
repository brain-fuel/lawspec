// User-owned LawSpec adapter.
package shop

import lawspec.data.Line
import lawspec.data.Money
import lawspec.data.ShopDomainCurrency
import lawspec.data.ShopOrdersCurrency
import lawspec.data.ShopTaxV2x0x0RatesBand

@groovy.transform.CompileStatic
final class Orders {
  static ShopDomainCurrency settlement(ShopOrdersCurrency value0) {
    switch (value0) {
      case ShopOrdersCurrency.Usd -> new ShopDomainCurrency.Usd()
      case ShopOrdersCurrency.Gbp -> new ShopDomainCurrency.Eur()
    }
  }

  static Money lineTotal(Line value0) {
    var price = value0.price()
    long count = value0.quantity().value()
    return new Money(price.currency(), Math.min(price.cents() * count, 100000000L))
  }

  static long cheaper(long value0, long value1) {
    return Math.min(value0, value1)
  }

  static long roundDown(long value0) {
    return value0 - value0 % 100
  }

  // Version 2 of shop.tax: no tax on nothing, the high band from 100.00.
  static ShopTaxV2x0x0RatesBand classify(long value0) {
    if (value0 <= 0) return new ShopTaxV2x0x0RatesBand.Zero()
    if (value0 < 10000) return new ShopTaxV2x0x0RatesBand.Low()
    return new ShopTaxV2x0x0RatesBand.High()
  }
}
