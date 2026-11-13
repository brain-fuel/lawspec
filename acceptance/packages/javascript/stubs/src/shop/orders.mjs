// User-owned LawSpec adapter.
// LawSpec argument currency1: shop.orders::type::Currency
// LawSpec result: shop.domain::type::Currency
export function settlement(currency1)
{
  throw new Error('settlement');
}

// LawSpec argument line1: shop.orders::type::Line
// LawSpec result: shop.domain::type::Money
export function lineTotal(line1)
{
  throw new Error('lineTotal');
}

// LawSpec argument int64_1: Int64
// LawSpec argument int64_2: Int64
// LawSpec result: Int64
export function cheaper(int64_1, int64_2)
{
  throw new Error('cheaper');
}

// LawSpec argument int64_1: Int64
// LawSpec result: Int64
export function roundDown(int64_1)
{
  throw new Error('roundDown');
}

// LawSpec argument int64_1: Int64
// LawSpec result: shop.tax.v2x0x0.rates::type::Band
export function classify(int64_1)
{
  throw new Error('classify');
}
