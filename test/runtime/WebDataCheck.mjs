import assert from 'node:assert/strict';
import test from 'node:test';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

const directory = process.env.LAWSPEC_DATA_DIR;
const extension = process.env.LAWSPEC_DATA_EXTENSION ?? 'mjs';
assert.ok(directory, 'Set LAWSPEC_DATA_DIR');
const load = name => import(pathToFileURL(path.join(
  directory, `${name}.${extension}`)).href);
const [data, ls, schema] = await Promise.all([
  load('lawspec_data'), load('lawspec_runtime'), load('lawspec_schema'),
]);
const registry = data.makeSchema();
const bits = Number(process.env.LAWSPEC_MACHINE_BITS ?? 64);
const tree = new schema.Named('Tree', [new schema.Named('Int8')]);
const pair = new schema.Named('Pair', [new schema.Named('Text')]);

test('recursive native values copy both conversion directions', () => {
  const source = new ls.DataValue('ctor::Branch', [[
    new ls.DataValue('ctor::Leaf', [127]),
    new ls.DataValue('ctor::Branch', [[]]),
  ]]);
  const native = registry.toNative(tree, source, bits);
  assert.ok(native instanceof data.TreeBranch);
  assert.ok(native.children[0] instanceof data.TreeLeaf);
  assert.equal(native.children[0].value, 127);
  const restored = registry.fromNative(tree, native, bits);
  assert.ok(registry.equal(tree, source, restored, bits));
  native.children.length = 0;
  assert.equal(source.fields[0].length, 2);
  assert.equal(restored.fields[0].length, 2);
  assert.throws(() => { native.children = []; }, TypeError);
});

test('unsigned maxima and supplementary characters remain exact', () => {
  const native = new data.PairPair('\u{1f642}', (1n << 64n) - 1n);
  const restored = registry.toNative(
    pair, registry.fromNative(pair, native, bits), bits);
  assert.equal(restored.first, native.first);
  assert.equal(restored.second, native.second);
  assert.throws(() => registry.fromNative(
    pair, new data.PairPair('ok', -1n), bits), /ctor::Pair.second/);
  assert.throws(() => registry.fromNative(
    pair, new data.PairPair('ok', Number(native.second)), bits),
    /ctor::Pair.second/);
});

test('raw units and arbitrary octets are copied without replacement', () => {
  for (const [name, payload] of [
    ['CodeUnit16', 0xd800], ['CodePoint', 0xdfff],
    ['Bytes', new Uint8Array([0, 128, 255])],
    ['Utf16Text', new ls.Raw('Utf16Text', [0xd800, 0, 0xdc00])],
    ['CodePointText', new ls.Raw('CodePointText', [0xd800, 0x1f642])],
  ]) {
    const type = new schema.Named('Tree', [new schema.Named(name)]);
    const logical = registry.fromNative(type, new data.TreeLeaf(payload), bits);
    const native = registry.toNative(type, logical, bits);
    assert.deepEqual(native.value, payload);
    if (payload instanceof Uint8Array) {
      payload.fill(1);
      assert.deepEqual(native.value, new Uint8Array([0, 128, 255]));
    }
  }
  assert.throws(() => registry.fromNative(
    new schema.Named('Tree', [new schema.Named('Text')]),
    new data.TreeLeaf('\ud800'), bits), /ctor::Leaf.value/);
});

test('algebraic absence and branches remain distinct', () => {
  const type = new schema.Named('Choice', [new schema.Named('Bool')]);
  const absent = registry.fromNative(
    type, new data.ChoiceChoose(new data.Left(new data.Nothing())), bits);
  const present = registry.fromNative(
    type, new data.ChoiceChoose(new data.Left(new data.Just(false))), bits);
  const right = registry.fromNative(type,
    new data.ChoiceChoose(new data.Right(new data.PairPair('x', 7n))), bits);
  assert.equal(registry.equal(type, absent, present, bits), false);
  assert.equal(registry.equal(type, absent, right, bits), false);
  const restored = registry.toNative(type, present, bits);
  assert.ok(restored.value instanceof data.Left);
  assert.ok(restored.value.value instanceof data.Just);
  assert.equal(restored.value.value.value, false);
});

test('nested presence does not collapse into outer absence', () => {
  const type = new schema.Named('Tree', [new schema.Named('Nullable', [
    new schema.Named('Optional', [new schema.Named('Int8')]),
  ])]);
  const native = new data.TreeLeaf(new data.Presence(
    'Nullable', true, new data.Presence('Optional', false)));
  const logical = registry.fromNative(type, native, bits);
  const restored = registry.toNative(type, logical, bits);
  assert.ok(restored.value instanceof data.Presence);
  assert.equal(restored.value.present, true);
  assert.equal(restored.value.value.present, false);
  assert.equal(registry.equal(type, logical, registry.fromNative(
    type, new data.TreeLeaf(new data.Presence('Nullable', false)), bits), bits),
    false);
});

test('IEEE and Symbol equality survive native bridges', () => {
  const floating = new schema.Named('Tree', [new schema.Named('Float64')]);
  const nan = registry.fromNative(floating, new data.TreeLeaf(NaN), bits);
  assert.equal(registry.equal(floating, nan, nan, bits), false);
  const value = number => registry.fromNative(
    floating, new data.TreeLeaf(number), bits);
  assert.ok(registry.equal(floating, value(0), value(-0), bits));
  assert.ok(registry.equal(floating, value(Infinity), value(Infinity), bits));
  const symbols = new schema.Named('Tree', [new schema.Named('Symbol')]);
  const first = Symbol('same');
  const a = registry.fromNative(symbols, new data.TreeLeaf(first), bits);
  const b = registry.fromNative(
    symbols, new data.TreeLeaf(Symbol('same')), bits);
  assert.ok(registry.equal(symbols, a, a, bits));
  assert.equal(registry.equal(symbols, a, b, bits), false);
  assert.equal(registry.toNative(symbols, a, bits).value, first);
});

test('malformed values fail contextually', () => {
  for (const value of [
    new ls.DataValue('foreign', []), new ls.DataValue('ctor::Leaf', []),
    new ls.DataValue('ctor::Leaf', [128]),
    new ls.DataValue('ctor::Leaf', [true]),
  ]) {
    assert.throws(() => registry.toNative(tree, value, bits), TypeError);
  }
  assert.throws(() => registry.fromNative(tree,
    new data.TreeBranch([new data.TreeLeaf(128)]), bits),
    /children: List\[0\].*value/);
  assert.throws(() => registry.fromNative(tree,
    new data.PairPair('x', 1n), bits), /invalid native Tree/);
  assert.throws(() => registry.fromNative(tree,
    new data.TreeBranch(new Array(1)), bits), /array holes/);
  assert.throws(() => registry.validate(new schema.Named('Empty', [
    new schema.Named('Bool'),
  ]), new ls.DataValue('invented', []), bits), /foreign constructor/);
});

test('matching evaluates only the selected branch', () => {
  const result = registry.match(tree, new ls.DataValue('ctor::Leaf', [9]), [
    ['ctor::Branch', () => assert.fail('unselected branch ran')],
    ['ctor::Leaf', value => value + 1],
  ], bits);
  assert.equal(result, 10);
});

test('fields named constructor and __proto__ remain ordinary payloads', () => {
  const type = new schema.Named('Reserved');
  const native = new data.ReservedToken(true, 'payload');
  assert.equal(Object.getPrototypeOf(native), data.ReservedToken.prototype);
  const restored = registry.toNative(type,
    registry.fromNative(type, native, bits), bits);
  assert.equal(restored.constructor, true);
  assert.equal(restored.__proto__, 'payload');
  assert.equal(Object.getPrototypeOf(restored), data.ReservedToken.prototype);
});

test('machine profile and type metadata are checked', () => {
  const machine = new schema.Named('Tree', [new schema.Named('UIntSize')]);
  assert.throws(() => registry.fromNative(machine,
    new data.TreeLeaf(1n << 32n), 32), /ctor::Leaf.value/);
  assert.equal(registry.toNative(machine, registry.fromNative(machine,
    new data.TreeLeaf(1n << 32n), 64), 64).value, 1n << 32n);
  for (const profile of [0, 16, true]) {
    assert.throws(() => registry.validate(tree,
      new ls.DataValue('ctor::Leaf', [1]), profile), /machineBits/);
  }
  const builtins = {nothing: data.Nothing, just: data.Just,
    left: data.Left, right: data.Right, presence: data.Presence};
  for (const type of [new schema.Parameter(0), new schema.Named('Unknown'),
    new schema.Named('List')]) {
    assert.throws(() => new schema.Schema([
      new schema.Definition('Box', 0, [new schema.Constructor('Box::Box', [
        new schema.Field('value', type),
      ], data.TreeLeaf)]),
    ], ['Bool'], builtins), TypeError);
  }
});
