// User-owned LawSpec adapter.
export function isWeekend(value0: number): boolean {
  return value0 === 0 || value0 === 6;
}

export function roundToDollars(value0: bigint): bigint {
  return value0 - (value0 % 100n);
}
