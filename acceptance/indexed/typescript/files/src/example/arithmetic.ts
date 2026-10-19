// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';

function length(row: data.Row): bigint {
  let count = 0n;
  for (; row instanceof data.RowCell; row = row.value.tail) count++;
  return count;
}

export function mirror(value0: data.Perfect): data.Perfect {
  if (value0 instanceof data.PerfectLeaf) return value0;
  return new data.PerfectNode(new data.Recordbf7449c93365b618bf1a5ee73f403facd0ee7b030d813d5e8c718611ac928ef8(mirror(value0.value.right), mirror(value0.value.left)));
}

export function area(value0: data.Grid): bigint {
  return length(value0.value.rows) * length(value0.value.columns);
}

export function duplicate(value0: data.Row): data.Halves {
  return new data.Halves(new data.Record90e2e86ad982c9c5e71a6cd286ab605cf2b3d771c37021fb930810c33933eb3d(value0, value0));
}

export function countPairs(value0: data.Row): data.Pairs {
  return new data.Pairs(value0);
}

export function dropFirst(value0: data.Row): data.Rest {
  return new data.Rest(value0);
}
