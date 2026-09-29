// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.mjs';

export function replicate(value0, value1) {
  let result = new data.VecVNil();
  for (let i = 0n; i < BigInt(value0); i++) result = new data.VecVCons(value1, result);
  return result;
}

export function append(value0, value1) {
  if (value0 instanceof data.VecVNil) return value1;
  return new data.VecVCons(value0.head, append(value0.tail, value1));
}

export function zip(value0, value1) {
  if (!(value0 instanceof data.VecVCons) || !(value1 instanceof data.VecVCons)) return new data.VecVNil();
  return new data.VecVCons(value1.head, zip(value0.tail, value1.tail));
}

export function flatten(value0) {
  if (!(value0 instanceof data.TreeBin)) return new data.VecVNil();
  const right = new data.VecVCons(value0.value, flatten(value0.right));
  return append(flatten(value0.left), right);
}
