// User-owned LawSpec adapter.
export function formatQuantity(value0: number): string {
  return String(value0);
}

export function parseQuantity(value0: string): number {
  return Number.parseInt(value0, 10);
}
