// User-owned LawSpec adapter.
export function applyDiscount(value0: bigint, value1: number): bigint {
  return (value0 * BigInt(100 - value1)) / 100n;
}
