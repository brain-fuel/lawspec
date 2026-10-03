// User-owned LawSpec adapter. A Duration holds its microseconds, a bigint.
import * as data from '.././lawspec_data.mjs';

export function remaining(value0, value1) {
  if (value1.value >= value0.value) return new data.Duration(0n);
  return new data.Duration(value0.value - value1.value);
}
