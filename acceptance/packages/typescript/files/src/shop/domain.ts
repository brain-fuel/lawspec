// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';

// One-to-one rates keep the example exact.
export function convert(value0: data.ShopDomainCurrency, value1: data.Money): data.Money {
  return new data.Money(value0, value1.cents);
}
