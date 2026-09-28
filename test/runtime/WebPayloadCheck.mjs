import assert from 'node:assert/strict';
import test from 'node:test';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

const directory = process.env.LAWSPEC_DATA_DIR ?? path.resolve(import.meta.dirname, '../../runtime');
const extension = process.env.LAWSPEC_DATA_EXTENSION ?? 'mjs';
const load = name => import(pathToFileURL(path.join(directory, `${name}.${extension}`)).href);
const [ls, {Schema, Definition, Constructor, Field, Named, Parameter}] =
  await Promise.all([load('lawspec_runtime'), load('lawspec_schema')]);
const named = (name, ...args) => new Named(name, args);
const variant = (tag, fields = [], predicates = []) => new Constructor(
  tag, fields.map(([name, type]) => new Field(name, type)), class {}, predicates);
const data = (tag, ...fields) => new ls.DataValue(tag, fields);
const builtins = Object.fromEntries(['nothing', 'just', 'left', 'right', 'presence']
  .map(name => [name, class {}]));
const int = named('Int8');
const a = new Parameter(0);
const b = new Parameter(1);
const tree = named('Tree', int);
const leaf = n => data('Tree::Leaf', n, -128);
const schema = new Schema([
  new Definition('Tree', 1, [
    variant('Tree::Leaf', [['value', a], ['fixed', int]]),
    variant('Tree::Forest', [['children', named('List', named('Tree', a))]]),
  ]),
  new Definition('Pair', 2, [variant('Pair::Pair', [['first', a], ['second', b]])]),
  new Definition('Nest', 1, [variant('Nest::Stop', [['value', a]]),
    variant('Nest::Next', [['child', named('Nest', named('List', a))]])]),
  new Definition('Phantom', 1, [variant('Phantom::Tag')]),
  new Definition('A', 2, [variant('A::End', [['value', a]]),
    variant('A::Next', [['child', named('B', b, a)]])]),
  new Definition('B', 2, [variant('B::End', [['value', a]]),
    variant('B::Next', [['child', named('A', b, a)]])]),
  new Definition('Wrapped', 1, [variant('Wrapped::Wrap', [['value',
    named('Nullable', named('Optional', named('List', a)))]])]),
], ['Int8', 'Bool'], builtins);
const positive = value => value > 0;
const negative = value => value < 0;
const unused = () => assert.fail('unstored predicate invoked');

test('recursive parameter occurrences exclude fixed fields at both widths', () => {
  for (const bits of [32, 64]) {
    for (const [n, expected] of [[1, true], [0, false]]) {
      let value = leaf(n);
      for (let depth = 0; depth < 40; depth++) value = data('Tree::Forest', [value]);
      assert.equal(schema.allPayloads(tree, value, [positive], bits), expected);
    }
  }
});
test('same concrete types preserve independent parameter roles', () => {
  for (const [first, second, expected] of [[1, -1, true], [-1, 1, false], [1, 1, false]]) {
    assert.equal(schema.allPayloads(named('Pair', int, int),
      data('Pair::Pair', first, second), [positive, negative]), expected);
  }
});
test('mutual recursion composes swapped parameter positions', () => {
  for (const [n, expected] of [[-1, true], [1, false]]) {
    assert.equal(schema.allPayloads(named('A', int, int),
      data('A::Next', data('B::End', n)), [positive, negative]), expected);
  }
});
test('growing arguments follow stored values rather than unfolding types', () => {
  for (const [values, expected] of [[[[1], [2]], true], [[[1], [0]], false]]) {
    assert.equal(schema.allPayloads(named('Nest', int),
      data('Nest::Next', data('Nest::Next', data('Nest::Stop', values))),
      [positive]), expected);
  }
});
test('empty, phantom and unselected storage never invokes callbacks', () => {
  assert.equal(schema.allPayloads(tree, data('Tree::Forest', []), [unused]), true);
  assert.equal(schema.allPayloads(named('Phantom', int), data('Phantom::Tag'), [unused]), true);
  assert.equal(schema.allPayloads(named('Maybe', int), data('Maybe::Nothing'), [unused]), true);
  assert.equal(schema.allPayloads(named('Either', int, int), data('Either::Right', 1),
    [unused, positive]), true);
  for (const kind of ['Nullable', 'Optional']) {
    assert.equal(schema.allPayloads(named(kind, int), new ls.Presence(kind, false), [unused]), true);
    assert.equal(schema.allPayloads(named(kind, int), new ls.Presence(kind, true, 1), [positive]), true);
  }
});
test('nested presence traverses parameter origins and preserves whole arguments', () => {
  for (const [values, expected] of [[[1, 2], true], [[1, 0], false]]) {
    const value = new ls.Presence('Nullable', true, new ls.Presence('Optional', true, values));
    assert.equal(schema.allPayloads(named('Wrapped', int), data('Wrapped::Wrap', value), [positive]), expected);
  }
  const value = new ls.Presence('Optional', false);
  assert.equal(schema.allPayloads(named('Tree', named('Optional', int)),
    data('Tree::Leaf', value, 0), [item => item instanceof ls.Presence]), true);
});
test('short circuits rejection and reports contextual callback faults', () => {
  const visited = [];
  const value = data('Tree::Forest', [leaf(0), leaf(2)]);
  assert.equal(schema.allPayloads(tree, value, [item => {
    visited.push(item);
    return item !== 0;
  }]), false);
  assert.deepEqual(visited, [0]);
  assert.throws(() => schema.allPayloads(tree, value, [() => { throw new Error('fault'); }]),
    /Tree::Forest.children: List\[0\]: Tree::Leaf.value: fault/);
  assert.throws(() => schema.allPayloads(tree, value, [() => null]), /did not produce Bool/);
  assert.throws(() => schema.allPayloads(tree, value, [() => { throw null; }]), /Tree::Leaf.value: null/);
});
test('validates shapes, callback metadata and constructor contracts first', () => {
  assert.throws(() => schema.allPayloads(tree, data('Tree::Leaf', 1, 128), [() => true]));
  assert.throws(() => schema.allPayloads(named('List', int), Array(1), [unused]), /holes/);
  assert.throws(() => schema.allPayloads(tree, leaf(1), []), /arity/);
  assert.throws(() => schema.allPayloads(tree, leaf(1), Array(1)), /callable/);
  assert.throws(() => schema.allPayloads(int, 1, []), /data type/);
  const checked = new Schema([new Definition('Checked', 1, [variant('Checked::Value',
    [['value', a]], [(_schema, _args, fields) => fields[0] > 0])])], ['Int8'], builtins);
  assert.throws(() => checked.allPayloads(named('Checked', int), data('Checked::Value', 0),
    [unused]), /field refinement 1 failed/);
});
