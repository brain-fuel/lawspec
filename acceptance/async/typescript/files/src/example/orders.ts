// User-owned LawSpec adapter.

function priceOf(sku: string): number {
  return sku === 'free' ? 0 : [...sku].length % 100;
}

export async function price(value0: string): Promise<number> {
  await Promise.resolve();
  return priceOf(value0);
}

export async function stock(value0: string): Promise<number> {
  return [...value0].length;
}

export function quote(value0: string): number {
  return priceOf(value0);
}
