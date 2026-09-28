import assert from 'node:assert/strict';
import test from 'node:test';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

const directory = process.env.LAWSPEC_DATA_DIR;
const extension = process.env.LAWSPEC_DATA_EXTENSION ?? 'mjs';
const load = name => import(pathToFileURL(path.join(
  directory, `${name}.${extension}`)).href);
const [data, ls, schema, generators, fc] = await Promise.all([
  load('lawspec_data'), load('lawspec_runtime'), load('lawspec_schema'),
  load('lawspec_data_strategies'),
  import(pathToFileURL(process.env.LAWSPEC_FAST_CHECK).href),
]);
const bits = Number(process.env.LAWSPEC_MACHINE_BITS ?? 64);
const named = (name, ...args) => new schema.Named(name, args);
const scalar = name => ({
  Bool: fc.boolean(), Int8: fc.integer({min: -128, max: 127}),
  Unit: fc.constant(ls.UNIT),
})[name];
const builtins = {nothing: data.Nothing, just: data.Just,
  left: data.Left, right: data.Right, presence: data.Presence};

function nodes(value) {
  if (value instanceof ls.DataValue) {
    return 1 + value.fields.reduce((sum, child) => sum + nodes(child), 0);
  }
  if (Array.isArray(value)) {
    return 1 + value.reduce((sum, child) => sum + nodes(child), 0);
  }
  if (value instanceof ls.Presence) {
    return 1 + (value.present ? nodes(value.value) : 0);
  }
  return 1;
}

function definition(name, fields) {
  return new schema.Definition(name, 0, [new schema.Constructor(
    `${name}::Make`, fields.map((type, index) =>
      new schema.Field(`field${index}`, type)), class {})]);
}

function witness(registry, type, budget, predicate) {
  const result = fc.check(fc.property(
    generators.strategy(registry, type, bits, budget, scalar), value => {
      registry.validate(type, value, bits);
      assert.ok(nodes(value) <= budget);
      return !predicate(value);
    }), {seed: 424242, numRuns: 500});
  assert.ok(result.failed, 'expected a counterexample');
  assert.equal(result.errorInstance?.message, 'Property failed by returning false');
  return result.counterexample[0];
}

test('uneven products reserve field minima and deep singletons fit', () => {
  const definitions = [definition('Deep0', [])];
  for (let index = 1; index <= 5; ++index) {
    definitions.push(definition(`Deep${index}`, [named(`Deep${index - 1}`)]));
  }
  definitions.push(definition('Uneven', [named('Deep5'),
    ...Array.from({length: 9}, () => named('Bool'))]));
  const registry = new schema.Schema(definitions, ['Bool'], builtins);
  const type = named('Uneven');
  assert.throws(() => generators.strategy(registry, type, bits, 15, scalar),
    /node budget/);
  fc.assert(fc.property(
    generators.strategy(registry, type, bits, 16, scalar), value => {
      registry.validate(type, value, bits);
      assert.equal(nodes(value), 16);
    }), {seed: 424242, numRuns: 100});
  const singleton = witness(registry, named('List', named('Deep5')), 7,
    value => value.length > 0);
  assert.equal(singleton.length, 1);
  assert.equal(nodes(singleton), 7);
});

test('native list length shrinking has no hidden four-element cap', () => {
  const registry = new schema.Schema([], ['Unit'], builtins);
  const value = witness(registry, named('List', named('Unit')), 10,
    value => value.length > 4);
  assert.equal(value.length, 5);
});

test('recursive shrinking keeps values valid and shrinks scalar payloads', () => {
  const registry = data.makeSchema();
  const type = named('Tree', named('Int8'));
  const positive = value => value.tag === 'ctor::Leaf' ?
    value.fields[0] > 0 : value.fields[0].some(positive);
  const value = witness(registry, type, 32, positive);
  assert.equal(value.tag, 'ctor::Leaf');
  assert.deepEqual(value.fields, [1]);
});

test('empty domains and absence respect constructor costs', () => {
  const registry = new schema.Schema([
    new schema.Definition('Empty', 0, []),
  ], ['Unit'], builtins);
  const empty = named('Empty');
  assert.throws(() => generators.strategy(registry, empty, bits, 16, scalar),
    /node budget/);
  for (const name of ['Maybe', 'Nullable', 'Optional']) {
    const type = named(name, empty);
    assert.throws(() => generators.strategy(registry, type, bits, 0, scalar),
      /positive/);
    assert.equal(nodes(witness(registry, type, 1, () => true)), 1);
  }
  const type = named('Either', empty, named('Unit'));
  assert.throws(() => generators.strategy(registry, type, bits, 1, scalar),
    /node budget/);
  const value = witness(registry, type, 2, () => true);
  assert.equal(value.tag, 'Either::Right');
  assert.equal(nodes(value), 2);
});
