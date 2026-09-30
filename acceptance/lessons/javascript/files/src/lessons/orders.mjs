// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.mjs';

export function price(value0) {
  const base = value0.size instanceof data.SizeLarge ? 320n : 250n;
  return base + BigInt(value0.shots) * 60n;
}
