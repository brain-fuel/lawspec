// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.mjs';

export function priceOf(value0) {
  if (value0 instanceof data.ItemEspresso) return 250n;
  if (value0 instanceof data.ItemLatte) return 350n;
  return 300n;
}

export function cheapest(value0, value1) {
  return value0 < value1 ? value0 : value1;
}
