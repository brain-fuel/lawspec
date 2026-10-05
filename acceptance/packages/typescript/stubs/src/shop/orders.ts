// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';
import * as schema from '.././lawspec_schema.js';
import * as ls from '../lawspec_runtime.js';
// LawSpec argument 0: shop.orders::type::Currency
// LawSpec result: shop.domain::type::Currency
export function settlement(
    value0: data.ShopOrdersCurrency
): data.ShopDomainCurrency {
  throw new Error('settlement');
}

// LawSpec argument 0: shop.orders::type::Line
// LawSpec result: shop.domain::type::Money
export function lineTotal(value0: data.Line): data.Money {
  throw new Error('lineTotal');
}

// LawSpec argument 0: Int64
// LawSpec argument 1: Int64
// LawSpec result: Int64
export function cheaper(value0: bigint, value1: bigint): bigint {
  throw new Error('cheaper');
}

// LawSpec argument 0: Int64
// LawSpec result: Int64
export function roundDown(value0: bigint): bigint {
  throw new Error('roundDown');
}

// LawSpec argument 0: Int64
// LawSpec result: shop.tax.v2_0_0.rates::type::Band
export function classify(value0: bigint): data.ShopTaxV200RatesBand {
  throw new Error('classify');
}
