// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';

function length(row: data.Row): bigint {
  let count = 0n;
  for (; row instanceof data.RowCell; row = row.value.tail) count++;
  return count;
}

export function mirror(value0: data.Perfect): data.Perfect {
  if (value0 instanceof data.PerfectLeaf) return value0;
  return new data.PerfectNode(new data.NodeDetails(mirror(value0.value.right), mirror(value0.value.left)));
}

export function area(value0: data.Grid): bigint {
  return length(value0.value.rows) * length(value0.value.columns);
}

export function duplicate(value0: data.Row): data.Halves {
  return new data.Halves(new data.HalvesDetails(value0, value0));
}

export function countPairs(value0: data.Row): data.Pairs {
  return new data.Pairs(value0);
}

export function dropFirst(value0: data.Row): data.Rest {
  return new data.Rest(value0);
}
