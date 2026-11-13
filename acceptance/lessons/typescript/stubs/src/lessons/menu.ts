// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';

// LawSpec argument item1: lessons.menu::type::Item
// LawSpec result: Int64
export function priceOf(item1: data.Item): bigint
{
  throw new Error('priceOf');
}

// LawSpec argument int64_1: Int64
// LawSpec argument int64_2: Int64
// LawSpec result: Int64
export function cheapest(int64_1: bigint, int64_2: bigint): bigint
{
  throw new Error('cheapest');
}
