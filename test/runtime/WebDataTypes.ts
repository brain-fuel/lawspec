import * as data from './lawspec_data.js';

export function leafValue(tree: data.Tree<number>): number {
  if (tree instanceof data.TreeLeaf) return tree.value;
  return tree.children.length;
}

export const tree: data.Tree<number> = new data.TreeBranch([
  new data.TreeLeaf(127), new data.TreeBranch<number>([]),
]);
export const pair: data.Pair<string> = new data.PairPair('x', (1n << 64n) - 1n);
export const choice: data.Choice<boolean> = new data.ChoiceChoose(
  new data.Left<data.Maybe<boolean>, data.Pair<string>>(new data.Just(false)),
);
export const absent: data.Maybe<data.Maybe<boolean>> = new data.Nothing();
// @ts-expect-error Payload type must be retained through a generic variant.
export const wrongTree: data.Tree<number> = new data.TreeLeaf('bad');
// @ts-expect-error UInt64 payloads use bigint, preserving their full range.
export const wrongPair: data.Pair<string> = new data.PairPair('x', 1);
// @ts-expect-error Distinct empty variants remain distinct nominal classes.
export const wrongAbsence: data.Nothing<boolean> = new data.TreeBranch([]);
// @ts-expect-error An empty type has no artificial inhabitant.
export const empty: data.Empty<boolean> = new data.Nothing();
