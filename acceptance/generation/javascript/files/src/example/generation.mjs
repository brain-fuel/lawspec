// User-owned LawSpec adapter: the portable generator under test.
import * as ls from '../lawspec_runtime.mjs';

export function generated(value0, value1, value2, value3) {
  return ls.generated(value0, value1, value2, value3);
}

export function shrunk(value0, value1, value2) {
  return ls.shrunk(value0, value1, value2);
}
