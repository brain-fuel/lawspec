// User-owned LawSpec adapter.
export function applyDiscount(value0, value1) {
  return (value0 * BigInt(100 - value1)) / 100n;
}
