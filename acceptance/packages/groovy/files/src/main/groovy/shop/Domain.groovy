// User-owned LawSpec adapter.
package shop

import lawspec.data.Money
import lawspec.data.ShopDomainCurrency

@groovy.transform.CompileStatic
final class Domain {
  // One-to-one rates keep the example exact.
  static Money convert(ShopDomainCurrency value0, Money value1) {
    return new Money(value0, value1.cents())
  }
}
