// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';

// LawSpec argument currency1: shop.domain::type::Currency
// LawSpec argument money1: shop.domain::type::Money
// LawSpec result: shop.domain::type::Money
export function convert(
  currency1: data.ShopDomainCurrency,
  money1: data.Money,
): data.Money
{
  throw new Error('convert');
}
