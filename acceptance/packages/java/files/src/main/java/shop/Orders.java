// User-owned LawSpec adapter.
package shop;

import lawspec.data.Line;
import lawspec.data.Money;
import lawspec.data.Quantity;
import lawspec.data.ShopDomainCurrency;
import lawspec.data.ShopOrdersCurrency;

public final class Orders {
  public static ShopDomainCurrency settlement(ShopOrdersCurrency value0) {
    if (value0 instanceof ShopOrdersCurrency.UsdCase) return new ShopDomainCurrency.UsdCase();
    return new ShopDomainCurrency.EurCase();
  }

  public static Money lineTotal(Line value0) {
    var line = (Line.LineCase) value0;
    var price = (Money.MoneyCase) line.price;
    long count = ((Quantity.QuantityCase) line.quantity).value;
    return new Money.MoneyCase(price.currency, Math.min(price.cents * count, 100000000L));
  }

  public static long cheaper(long value0, long value1) {
    return Math.min(value0, value1);
  }

  public static long roundDown(long value0) {
    return value0 - value0 % 100;
  }
}
