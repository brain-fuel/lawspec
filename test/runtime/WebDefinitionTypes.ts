import * as total from './lawspec_definitions/example/total.js';
import * as other from './lawspec_definitions/other.js';
import * as data from './lawspec_data.js';

const symbols = new Map<string, symbol>();
export const size: bigint = total.size(symbols, [127]);
export const treeSum: bigint = total.sumTree(symbols, new data.TreeLeaf(127));
export const count: bigint = other.pairCount(symbols, [new data.PairPair(127, true)]);
export const absent: data.Presence<data.Presence<number>> = total.absent(
    symbols, new data.Presence('Optional', true, new data.Presence('Nullable', false)));
// @ts-expect-error List elements retain their native number type.
total.size(symbols, ['wrong']);
// @ts-expect-error Recursive products retain native nominal types.
total.sumTree(symbols, true);
// @ts-expect-error Maybe payloads must retain number.
total.maybeDefault(symbols, new data.Just(true));
// @ts-expect-error Nested presence payloads cannot collapse to Bool.
total.absent(symbols, new data.Presence('Optional', true, true));
// @ts-expect-error Product parameters remain distinct.
other.pairCount(symbols, [new data.PairPair(true, 127)]);
// @ts-expect-error Exact promoted integer results are bigint.
export const rounded: number = total.increment(symbols, 127);
