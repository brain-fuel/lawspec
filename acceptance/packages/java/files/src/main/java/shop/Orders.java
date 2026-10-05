// User-owned LawSpec adapter.
package shop;

import lawspec.data.Line;
import lawspec.data.Money;
import lawspec.data.ShopDomainCurrency;
import lawspec.data.ShopOrdersCurrency;
import lawspec.data.ShopTaxV2x0x0RatesBand;

public final class Orders {
  public static ShopDomainCurrency settlement(ShopOrdersCurrency value0) {
    return switch (value0) {
      case ShopOrdersCurrency.Usd usd -> new ShopDomainCurrency.Usd();
      case ShopOrdersCurrency.Gbp gbp -> new ShopDomainCurrency.Eur();
    };
  }

  public static Money lineTotal(Line value0) {
    var price = value0.price();
    long count = value0.quantity().value();
    return new Money(price.currency(), Math.min(price.cents() * count, 100000000L));
  }

  public static long cheaper(long value0, long value1) {
    return Math.min(value0, value1);
  }

  public static long roundDown(long value0) {
    return value0 - value0 % 100;
  }

  // Version 2 of shop.tax: no tax on nothing, the high band from 100.00.
  public static ShopTaxV2x0x0RatesBand classify(long value0) {
    if (value0 <= 0) return new ShopTaxV2x0x0RatesBand.Zero();
    if (value0 < 10000) return new ShopTaxV2x0x0RatesBand.Low();
    return new ShopTaxV2x0x0RatesBand.High();
  }
}
