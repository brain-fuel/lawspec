// Source-only native checks; no property framework is imported here.
import assert from 'node:assert/strict';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

const directory = process.env.LAWSPEC_DEFINITIONS_DIR;
const extension = process.env.LAWSPEC_DATA_EXTENSION;
const bits = Number(process.env.LAWSPEC_MACHINE_BITS);
const load = name => import(pathToFileURL(path.join(directory, `${name}.${extension}`)));
const [total, other, data, ls] = await Promise.all([
  load('lawspec_definitions/example/total'), load('lawspec_definitions/other'),
  load('lawspec_data'), load('lawspec_runtime'),
]);
const symbols = new Map();
assert.equal(total.size(symbols, []), 0n);
assert.equal(total.forward(symbols, [1, 2, 3]), 3n);
assert.equal(total.sumList(symbols, [127, 127]), 254n);
assert.equal(total.increment(symbols, 127), 128n);
assert.equal(total.divisible(symbols, 5n, 0n), false);
assert.equal(total.divisible(symbols, -6n, 3n), true);
assert.equal(total.divisible(symbols, -5n, 3n), false);
assert.equal(total.sumTree(symbols, new data.TreeBranch(new data.TreeLeaf(127), new data.TreeLeaf(127))), 254n);
assert.equal(other.size(symbols, true), true);
assert.equal(other.quotedSymbol(symbols, ls.UNIT).description, "it's \\ a\n😀\u2028".repeat(8));
assert.equal(other.pairCount(symbols, [new data.PairPair(127, true)]), 1n);
assert.equal(total.maybeDefault(symbols, new data.Nothing()), 0);
assert.equal(total.maybeDefault(symbols, new data.Just(127)), 127);
const raw = [0xd800, 0xdc00, 0xffff];
const copied = total.raw(symbols, raw);
assert.deepEqual(copied, raw);
assert.notEqual(copied, raw);
raw[0] = 0;
assert.equal(copied[0], 0xd800);
for (const value of [
  new data.Presence('Optional', false),
  new data.Presence('Optional', true, new data.Presence('Nullable', false)),
  new data.Presence('Optional', true, new data.Presence('Nullable', true, 127)),
]) {
  const result = total.absent(symbols, value);
  assert.equal(ls.equal(result, value, 'Optional Nullable Int8', 'Optional Nullable Int8'), true);
}
assert.equal(total.symbol(symbols, ls.UNIT), total.symbol(symbols, ls.UNIT));
assert.notEqual(total.symbol(new Map(), ls.UNIT), total.symbol(new Map(), ls.UNIT));
assert.equal(ls.equal(total.exact(symbols, new ls.Decimal(1n, -1n)), new ls.Decimal(3n, -1n), 'Decimal', 'Decimal'), true);
assert.equal(total.either(symbols, new data.Left(127)).value, 127);
assert.equal(total.either(symbols, new data.Right(true)).value, true);
const maximum = (1n << BigInt(bits - 1)) - 1n;
assert.equal(total.machine(symbols, maximum), maximum);
assert.ok(total.architecture(symbols, new data.ArchitectureUnused()) instanceof data.ArchitectureUnused);
assert.equal(total.architecture(symbols, new data.ArchitectureNative(maximum)).size, maximum);
for (const [method, value] of [
  [total.machine, maximum + 1n],
  [total.architecture, new data.ArchitectureNative(maximum + 1n)],
  [total.increment, true], [total.increment, 128], [total.increment, 1.5],
  [total.size, ['wrong']], [total.size, new Array(1)],
  [total.sumTree, true], [total.maybeDefault, new data.Just(true)],
  [total.absent, new data.Presence('Optional', true, true)],
]) {
  assert.throws(() => method(symbols, value), error =>
    error.message.includes(`example.total::${method.name}:`));
}
console.log(`Web standalone definition calls passed: ${extension}/${bits}`);
