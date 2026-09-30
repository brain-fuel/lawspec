// User-owned LawSpec adapter.
export function priceInCents(value0) {
  return BigInt(value0) * (value0 >= 10 ? 225n : 250n);
}
