// User-owned LawSpec adapter.

function priceOf(sku) {
  return sku === 'free' ? 0 : [...sku].length % 100;
}

export async function price(value0) {
  await Promise.resolve();
  return priceOf(value0);
}

export async function stock(value0) {
  return [...value0].length;
}

export function quote(value0) {
  return priceOf(value0);
}
