// Application code the warehouse adapters are bound to: some of it
// asynchronous, as a real service client would be.

function price(sku: string): number {
  return sku === 'free' ? 0 : [...sku].length % 100;
}

export async function priceOf(sku: string): Promise<number> {
  await Promise.resolve();
  return price(sku);
}

export function quoteOf(sku: string): number {
  return price(sku);
}

// A stock count that several callers may change.
export class Shelf {
  total = 0n;

  async restock(amount: number): Promise<void> {
    await Promise.resolve();
    this.total += BigInt(amount);
  }

  async count(): Promise<bigint> {
    await Promise.resolve();
    return this.total;
  }
}
