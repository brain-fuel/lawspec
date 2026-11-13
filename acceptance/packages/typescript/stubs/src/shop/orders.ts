// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';

// LawSpec argument currency1: shop.orders::type::Currency
// LawSpec result: shop.domain::type::Currency
export function settlement(
  currency1: data.ShopOrdersCurrency,
): data.ShopDomainCurrency
{
  throw new Error('settlement');
}

// LawSpec argument line1: shop.orders::type::Line
// LawSpec result: shop.domain::type::Money
export function lineTotal(line1: data.Line): data.Money
{
  throw new Error('lineTotal');
}

// LawSpec argument int64_1: Int64
// LawSpec argument int64_2: Int64
// LawSpec result: Int64
export function cheaper(int64_1: bigint, int64_2: bigint): bigint
{
  throw new Error('cheaper');
}

// LawSpec argument int64_1: Int64
// LawSpec result: Int64
export function roundDown(int64_1: bigint): bigint
{
  throw new Error('roundDown');
}

// LawSpec argument int64_1: Int64
// LawSpec result: shop.tax.v2x0x0.rates::type::Band
export function classify(int64_1: bigint): data.ShopTaxV2x0x0RatesBand
{
  throw new Error('classify');
}
