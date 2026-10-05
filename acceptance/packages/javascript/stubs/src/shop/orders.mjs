// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.mjs';
import * as schema from '.././lawspec_schema.mjs';
import * as ls from '../lawspec_runtime.mjs';
// LawSpec argument 0: shop.orders::type::Currency
// LawSpec result: shop.domain::type::Currency
export function settlement(value0) {
  throw new Error('settlement');
}

// LawSpec argument 0: shop.orders::type::Line
// LawSpec result: shop.domain::type::Money
export function lineTotal(value0) {
  throw new Error('lineTotal');
}

// LawSpec argument 0: Int64
// LawSpec argument 1: Int64
// LawSpec result: Int64
export function cheaper(value0, value1) {
  throw new Error('cheaper');
}

// LawSpec argument 0: Int64
// LawSpec result: Int64
export function roundDown(value0) {
  throw new Error('roundDown');
}

// LawSpec argument 0: Int64
// LawSpec result: shop.tax.v2x0x0.rates::type::Band
export function classify(value0) {
  throw new Error('classify');
}
