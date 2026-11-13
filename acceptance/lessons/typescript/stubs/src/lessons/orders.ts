// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';

// LawSpec argument drink1: lessons.orders::type::Drink
// LawSpec result: Int64
export function price(drink1: data.Drink): bigint
{
  throw new Error('price');
}
