// User-owned LawSpec adapter: the portable generator under test.
import * as ls from '../lawspec_runtime.js';

export function generated(value0: string, value1: bigint, value2: number, value3: number): Array<string> {
  return ls.generated(value0, value1, value2, value3);
}

export function shrunk(value0: string, value1: bigint, value2: number): Array<string> {
  return ls.shrunk(value0, value1, value2);
}
