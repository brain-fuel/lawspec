// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';

export function priceOf(value0: data.Item): bigint {
  if (value0 instanceof data.ItemEspresso) return 250n;
  if (value0 instanceof data.ItemLatte) return 350n;
  return 300n;
}

export function cheapest(value0: bigint, value1: bigint): bigint {
  return value0 < value1 ? value0 : value1;
}
