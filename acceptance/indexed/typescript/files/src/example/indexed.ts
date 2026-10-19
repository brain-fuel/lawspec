// User-owned LawSpec adapter.
import * as data from '.././lawspec_data.js';

export function replicate(value0: bigint, value1: number): data.Vec<number> {
  let result: data.Vec<number> = new data.VecVNil();
  for (let i = 0n; i < BigInt(value0); i++) result = new data.VecVCons(new data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(value1, result));
  return result;
}

export function append(value0: data.Vec<number>, value1: data.Vec<number>): data.Vec<number> {
  if (value0 instanceof data.VecVNil) return value1;
  return new data.VecVCons(new data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(value0.value.head, append(value0.value.tail, value1)));
}

export function zip(value0: data.Vec<number>, value1: data.Vec<boolean>): data.Vec<boolean> {
  if (!(value0 instanceof data.VecVCons) || !(value1 instanceof data.VecVCons)) return new data.VecVNil();
  return new data.VecVCons(new data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(value1.value.head, zip(value0.value.tail, value1.value.tail)));
}

export function flatten(value0: data.Tree<number>): data.Vec<number> {
  if (!(value0 instanceof data.TreeBin)) return new data.VecVNil();
  const right = new data.VecVCons(new data.Record4715df484a923df1661009999090568502db4ab1a072eddf70dc05c9f83e9cec(value0.value.value, flatten(value0.value.right)));
  return append(flatten(value0.value.left), right);
}
