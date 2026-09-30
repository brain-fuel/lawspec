// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';

export function price(value0: data.Drink): bigint {
  const base = value0.size instanceof data.SizeLarge ? 320n : 250n;
  return base + BigInt(value0.shots) * 60n;
}
