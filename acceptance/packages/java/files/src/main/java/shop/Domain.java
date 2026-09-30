// User-owned LawSpec adapter.
package shop;

import lawspec.data.Money;
import lawspec.data.ShopDomainCurrency;

public final class Domain {
  // One-to-one rates keep the example exact.
  public static Money convert(ShopDomainCurrency value0, Money value1) {
    return new Money.MoneyCase(value0, ((Money.MoneyCase) value1).cents);
  }
}
