// Application code the warehouse adapters are bound to: some of it
// asynchronous, as a real service client would be.

function price(sku) {
  return sku === 'free' ? 0 : [...sku].length % 100;
}

export async function priceOf(sku) {
  await Promise.resolve();
  return price(sku);
}

export function quoteOf(sku) {
  return price(sku);
}

// A stock count that several callers may change.
export class Shelf {
  constructor() {
    this.total = 0n;
  }

  async restock(amount) {
    await Promise.resolve();
    this.total += BigInt(amount);
  }

  async count() {
    await Promise.resolve();
    return this.total;
  }
}
