import assert from 'node:assert/strict';
import test from 'node:test';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

const extension = process.env.LAWSPEC_DATA_EXTENSION ?? 'mjs';
const load = name => import(pathToFileURL(path.join(
  process.env.LAWSPEC_DATA_DIR, `${name}.${extension}`)).href);
const [data, ls, schema, generators, fc] = await Promise.all([
  load('lawspec_data'), load('lawspec_runtime'), load('lawspec_schema'),
  load('lawspec_data_strategies'),
  import(pathToFileURL(process.env.LAWSPEC_FAST_CHECK).href),
]);
const bits = Number(process.env.LAWSPEC_MACHINE_BITS ?? 64);
const named = (name, ...args) => new schema.Named(name, args);
const builtins = {nothing: data.Nothing, just: data.Just,
  left: data.Left, right: data.Right, presence: data.Presence};
class Gap {
  constructor(first, second) { this.first = first; this.second = second; }
}
class Box {
  constructor(value) { this.value = value; }
}
const gap = (a, b) => new ls.DataValue('Gap::Gap', [a, b]);
function gaps(predicates = [(registry, args, fields) => fields[1] > fields[0]]) {
  return new schema.Schema([new schema.Definition('Gap', 0, [
    new schema.Constructor('Gap::Gap', [new schema.Field('first', named('Int8')),
      new schema.Field('second', named('Int8'))], Gap, predicates),
  ])], ['Int8'], builtins);
}

test('all bridges, matching and equality enforce dependent fields', () => {
  const registry = gaps();
  const type = named('Gap');
  const valid = gap(-128, 127);
  assert.deepEqual(registry.toNative(type, valid, bits), new Gap(-128, 127));
  assert.equal(registry.equal(type, valid,
    registry.fromNative(type, new Gap(-128, 127), bits), bits), true);
  assert.equal(registry.match(type, valid,
    [['Gap::Gap', (a, b) => b - a]], bits), 255);
  for (const action of [
    () => registry.validate(type, gap(1, 0), bits),
    () => registry.toNative(type, gap(1, 0), bits),
    () => registry.fromNative(type, new Gap(1, 0), bits),
    () => registry.construct(type, 'Gap::Gap', [1, 0], bits),
    () => registry.match(type, gap(1, 0), [], bits),
    () => registry.equal(type, valid, gap(1, 0), bits),
    () => registry.validate(named('List', type), [gap(1, 0)], bits),
  ]) assert.throws(action, schema.RefinementViolation);
});

test('predicates are ordered and require an actual Boolean result', () => {
  const registry = gaps([() => false, () => { throw Error('must not run'); }]);
  assert.throws(() => registry.validate(named('Gap'), gap(0, 1), bits),
    schema.RefinementViolation);
  for (const predicate of [() => 1, () => { throw Error('broken'); }]) {
    assert.throws(() => gaps([predicate]).validate(named('Gap'), gap(0, 1), bits),
      error => error instanceof TypeError &&
        !(error instanceof schema.RefinementViolation));
  }
  assert.throws(() => gaps([true]), /must be callable/);
});

test('nested Symbol fixtures retain the caller identity context', () => {
  const wire = {type: 'Symbol', id: 'fixture', description: 'same'};
  const symbols = new Map();
  const expected = ls.literal(wire, symbols);
  const registry = new schema.Schema([new schema.Definition('Box', 1, [
    new schema.Constructor('Box::Box', [new schema.Field('value',
      new schema.Parameter(0))], Box, [(registry, args, fields, width, context) => {
      assert.equal(args[0].name, 'Symbol');
      assert.equal(width, bits);
      return fields[0] === ls.literal(wire, context);
    }]),
  ])], ['Symbol'], builtins);
  const type = named('List', named('Box', named('Symbol')));
  const logical = registry.fromNative(type, [new Box(expected)], bits, symbols);
  assert.equal(registry.toNative(type, logical, bits, symbols)[0].value, expected);
  assert.equal(registry.equal(type, logical, logical, bits, symbols), true);
  assert.throws(() => registry.validate(type, logical, bits, new Map()),
    schema.RefinementViolation);
  assert.throws(() => registry.fromNative(type, [new Box(Symbol('same'))],
    bits, symbols), schema.RefinementViolation);
  for (const wrapper of ['Nullable', 'Optional', 'Maybe', 'Either']) {
    const inner = named('Box', named('Symbol'));
    const wrapped = wrapper === 'Either' ? named(wrapper, inner, inner)
      : named(wrapper, inner);
    const box = logical[0];
    const value = wrapper === 'Nullable' || wrapper === 'Optional'
      ? new ls.Presence(wrapper, true, box)
      : new ls.DataValue(wrapper === 'Maybe' ? 'Maybe::Just' : 'Either::Right',
        [box]);
    assert.equal(registry.equal(wrapped, value, value, bits, symbols), true);
    assert.equal(registry.equal(wrapped, value, registry.fromNative(wrapped,
      registry.toNative(wrapped, value, bits, symbols), bits, symbols),
    bits, symbols), true);
  }
  const arbitrary = generators.strategy(registry, named('Box', named('Symbol')),
    bits, 2, () => fc.constant(expected), symbols);
  fc.assert(fc.property(arbitrary, value => {
    assert.equal(value.fields[0], expected);
    registry.validate(named('Box', named('Symbol')), value, bits, symbols);
  }), {seed: 424242, numRuns: 30});
});

test('native generation retries full tuples and retains shrinking', () => {
  const registry = gaps();
  const type = named('Gap');
  const arbitrary = generators.strategy(registry, type, bits, 3,
    () => fc.integer({min: -128, max: 127}));
  fc.assert(fc.property(arbitrary, value => {
    registry.validate(type, value, bits);
    assert.ok(value.fields[1] > value.fields[0]);
  }), {seed: 424242, numRuns: 200});
  const result = fc.check(fc.property(arbitrary,
    value => value.fields[1] - value.fields[0] < 6),
  {seed: 424242, numRuns: 500});
  assert.ok(result.failed);
  assert.ok(result.numShrinks > 0);
  const [a, b] = result.counterexample[0].fields;
  assert.ok(b - a >= 6);
  registry.validate(type, result.counterexample[0], bits);
});

test('generator predicate errors escape instead of being discarded', () => {
  const registry = gaps([() => { throw Error('broken predicate'); }]);
  assert.throws(() => fc.sample(generators.strategy(registry, named('Gap'),
    bits, 3, () => fc.constant(1)), 1), /broken predicate/);
});

test('witnesses seed nested fixture identities beyond the original sample', () => {
  const wire = {type: 'Symbol', id: 'fixture', description: 'same'};
  const symbols = new Map();
  const expected = ls.literal(wire, symbols);
  const registry = new schema.Schema([new schema.Definition('Box', 0, [
    new schema.Constructor('Box::Box', [new schema.Field('value', named('Symbol'))],
      Box, [(registry, args, fields, width, context) =>
        fields[0] === ls.literal(wire, context)]),
  ])], ['Symbol'], builtins);
  const type = named('List', named('Box'));
  const seed = [new ls.DataValue('Box::Box', [expected])];
  const arbitrary = generators.strategy(registry, type, bits, 7,
    () => fc.string().map(value => Symbol(value)), symbols, [seed]);
  const result = fc.check(fc.property(arbitrary, values => {
    registry.validate(type, values, bits, symbols);
    for (const value of values) assert.equal(value.fields[0], expected);
    return values.length !== 3;
  }), {seed: 424242, numRuns: 100});
  assert.ok(result.failed);
  assert.equal(result.counterexample[0].length, 3);
  assert.throws(() => generators.strategy(registry, type, bits, 7,
    () => fc.constant(expected), new Map(), [seed]), schema.RefinementViolation);
});

test('witnesses fit nested node budgets and retain native candidates', () => {
  const registry = gaps();
  const type = named('List', named('Gap'));
  const arbitrary = generators.strategy(registry, type, bits, 4,
    () => fc.integer({min: 0, max: 16}), new Map(), [[gap(-128, 127), gap(-128, 127)]]);
  fc.assert(fc.property(arbitrary, values => {
    assert.ok(values.length <= 1);
    registry.validate(type, values, bits);
  }), {seed: 424242, numRuns: 100});
  const result = fc.check(fc.property(arbitrary, values => {
    if (!values.length) return true;
    const [a, b] = values[0].fields;
    return !(0 <= a && a < b && b <= 16 && b - a >= 6);
  }), {seed: 424242, numRuns: 500});
  assert.ok(result.failed);
  assert.ok(result.numShrinks > 0);
  assert.throws(() => generators.strategy(registry, type, bits, 4,
    () => fc.constant(0), new Map(), [[gap(1, 0)]]), schema.RefinementViolation);
});

test('impossible contracts exhaust explicitly and sum alternatives remain viable', () => {
  let attempts = 0;
  const registry = gaps([() => { attempts++; return false; }]);
  const arbitrary = generators.strategy(registry, named('Gap'), bits, 3,
    () => fc.constant(0), new Map(), [], 5);
  assert.throws(() => fc.sample(arbitrary, 1), /generation exhausted/);
  assert.equal(attempts, 5);
  for (const maximum of [0, -1, 1.5, Infinity]) {
    assert.throws(() => generators.strategy(registry, named('Gap'), bits, 3,
      () => fc.constant(0), new Map(), [], maximum), /attempt budget/);
  }
  class Empty {}
  const choice = new schema.Schema([new schema.Definition('Choice', 0, [
    new schema.Constructor('Never', [], Gap, [() => false]),
    new schema.Constructor('Some', [], Empty),
  ])], [], builtins);
  fc.assert(fc.property(generators.strategy(choice, named('Choice'), bits, 1,
    () => { throw Error('no primitive required'); }),
  value => value.tag === 'Some'), {seed: 424242, numRuns: 100});
});


test('an impossible nested branch does not exhaust a viable enclosing sum', () => {
  class Never {}
  class Child { constructor(value) { this.value = value; } }
  class Done {}
  const registry = new schema.Schema([
    new schema.Definition('Never', 0, [new schema.Constructor('Never', [],
      Never, [() => false])]),
    new schema.Definition('Outer', 0, [
      new schema.Constructor('Child', [new schema.Field('value', named('Never'))],
        Child),
      new schema.Constructor('Done', [], Done),
    ]),
  ], [], builtins);
  const arbitrary = generators.strategy(registry, named('Outer'), bits, 2,
    () => { throw Error('no primitive required'); });
  fc.assert(fc.property(arbitrary, value => value.tag === 'Done'),
    {seed: 424242, numRuns: 100});
});
