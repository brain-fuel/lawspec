// User-owned LawSpec adapter. A Duration holds its microseconds, a bigint.
import * as data from '.././lawspec_data.js';

export function remaining(value0: data.Duration, value1: data.Duration): data.Duration {
  if (value1.value >= value0.value) return new data.Duration(0n);
  return new data.Duration(value0.value - value1.value);
}
