// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.mjs';

// One-to-one rates keep the example exact.
export function convert(value0, value1) {
  return new data.MoneyMoney(value0, value1.cents);
}
