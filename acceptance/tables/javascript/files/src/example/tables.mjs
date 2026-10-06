// User-owned LawSpec adapters for the tables example.

// LawSpec argument 0: Int32
// LawSpec argument 1: Int32
// LawSpec result: Int32
export function shippingCost(value0, value1) {
  return value0 * value1 + 5 * value0;
}

// LawSpec argument 0: Int32
// LawSpec result: Text
export function label(value0) {
  return `parcel ${value0}`;
}
