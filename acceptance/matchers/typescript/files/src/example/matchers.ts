// User-owned LawSpec adapters for the matchers example.
import * as data from '.././lawspec_data.js';

// LawSpec argument 0: List (Int32)
// LawSpec result: List (Int32)
export function sortItems(value0: Array<number>): Array<number> {
  return [...value0].sort((a, b) => a - b);
}

// LawSpec argument 0: List (Text)
// LawSpec result: List (Text)
export function uniqueTags(value0: Array<string>): Array<string> {
  return [...new Set(value0)];
}

// LawSpec argument 0: Int32
// LawSpec argument 1: Int32
// LawSpec result: Float64
export function average(value0: number, value1: number): number {
  return (value0 + value1) / 2;
}

// LawSpec argument 0: Text
// LawSpec result: Text
export function slug(value0: string): string {
  return (value0.toLowerCase().match(/[a-z0-9]+/g) ?? []).join('-');
}

// LawSpec argument 0: Int32
// LawSpec result: example.matchers::type::Order
export function ship(value0: number): data.Order {
  return new data.OrderShipped(value0, 'post');
}
