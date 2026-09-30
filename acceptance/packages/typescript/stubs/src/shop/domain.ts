// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';
import * as schema from '.././lawspec_schema.js';
import * as ls from '../lawspec_runtime.js';
// LawSpec argument 0: shop.domain::type::Currency
// LawSpec argument 1: shop.domain::type::Money
// LawSpec result: shop.domain::type::Money
export function convert(
    value0: data.ShopDomainCurrency,
    value1: data.Money
): data.Money {
  throw new Error('convert');
}
