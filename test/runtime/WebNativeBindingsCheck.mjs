import assert from 'node:assert/strict';
import test from 'node:test';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

const extension = process.env.LAWSPEC_DATA_EXTENSION ?? 'mjs';
const load = name => import(pathToFileURL(path.join(
  name === 'lawspec_data_strategies' && process.env.LAWSPEC_STRATEGIES_DIR
    ? process.env.LAWSPEC_STRATEGIES_DIR : process.env.LAWSPEC_DATA_DIR,
  `${name}.${extension}`)).href);
const [data, ls, schema, generators, fc] = await Promise.all([
  load('lawspec_data'), load('lawspec_runtime'), load('lawspec_schema'),
  load('lawspec_data_strategies'),
  import(pathToFileURL(process.env.LAWSPEC_FAST_CHECK).href),
]);
const named = (name, ...args) => new schema.Named(name, args);
const builtins = {nothing:data.Nothing, just:data.Just, left:data.Left,
  right:data.Right, presence:data.Presence};
class Node {
  constructor(value, children) { this.value = value; this.children = children; }
}
class NativeNode {
  constructor({descendants, payload}) {
    this.descendants = descendants;
    this.payload = payload;
  }
}
function registry(predicates = []) {
  return new schema.Schema([new schema.Definition('Node', 1, [
    new schema.Constructor('Node::Node', [
      new schema.Field('value', new schema.Parameter(0)),
      new schema.Field('children', named('List', named('Node',
        new schema.Parameter(0)))),
    ], Node, predicates),
  ])], ['Int8', 'Symbol'], builtins);
}
const bindings = [['Node::Node', {native:NativeNode,
  fields:['payload', 'descendants']}]];
const node = (value, children = []) => new ls.DataValue('Node::Node',
  [value, children]);

test('native mappings preserve generic recursion and schema independence', () => {
  const canonical = registry();
  const native = canonical.withNativeBindings(bindings);
  const ty = named('Node', named('Int8'));
  const logical = node(12, [node(5)]);
  const value = native.toNative(ty, logical);
  assert.ok(value instanceof NativeNode);
  assert.equal(value.descendants[0].payload, 5);
  assert.ok(canonical.equal(ty, native.fromNative(ty, value), logical));
  assert.ok(canonical.toNative(ty, logical) instanceof Node);
  assert.throws(() => native.fromNative(ty, new Node(12, [])), /invalid native/);
  value.descendants[0].payload = 128;
  assert.throws(() => native.fromNative(ty, value), /Node::Node.children/);
});

test('native mappings retain Symbol identity and constructor predicates', () => {
  const native = registry().withNativeBindings(bindings);
  const ty = named('Node', named('Symbol'));
  const symbol = Symbol('description');
  const result = native.fromNative(ty, native.toNative(ty, node(symbol)));
  assert.equal(result.fields[0], symbol);
  const positive = registry([(s, a, fields) => fields[0] > 0])
    .withNativeBindings(bindings);
  assert.throws(() => positive.fromNative(named('Node', named('Int8')),
    new NativeNode({payload:-1, descendants:[]})), /field refinement/);
});

test('invalid native mappings fail registration', () => {
  for (const fields of [[], ['payload'], ['payload', 'payload']]) {
    assert.throws(() => registry().withNativeBindings([
      ['Node::Node', {native:NativeNode, fields}],
    ]), /native field mapping/);
  }
  assert.throws(() => registry().withNativeBindings([
    ['Missing', {native:NativeNode, fields:[]}],
  ]), /unknown native constructor/);
});

function strategy(type, factories, witnesses = []) {
  const canonical = registry();
  return generators.strategy(canonical, type, 64, 32,
    () => fc.integer({min:-128, max:127}), new Map(), witnesses, 10,
    new Map(factories), canonical.withNativeBindings(bindings));
}

test('generic native factories compose child arbitraries and retain shrinking', () => {
  const arb = strategy(named('Node', named('Int8')), [
    ['Int8', () => fc.integer({min:40, max:100})],
    ['Node', child => child.map(payload =>
      new NativeNode({payload, descendants:[]}))],
  ]);
  const checked = fc.check(fc.property(arb, value => value.fields[0] < 61),
    {seed:2026, numRuns:100});
  assert.equal(checked.failed, true);
  assert.equal(checked.counterexample[0].fields[0], 61);
});

test('invalid custom samples fail contextually', () => {
  const arb = strategy(named('Int8'), [['Int8', () => fc.constant(true)]]);
  assert.throws(() => fc.sample(arb, 1), /native generator Int8/);
});

test('invalid native shrinks fail instead of being filtered', () => {
  class InvalidShrink extends fc.Arbitrary {
    generate() { return new fc.Value(42, undefined); }
    canShrinkWithoutContext() { return true; }
    shrink() { return fc.Stream.of(new fc.Value(true, undefined)); }
  }
  const arb = strategy(named('Int8'), [['Int8', () => new InvalidShrink()]]);
  const value = arb.generate(undefined, undefined);
  assert.equal(value.value, 42);
  assert.throws(() => [...arb.shrink(value.value, value.context)],
    /native generator Int8/);
});

test('exhausted custom arbitraries cannot fall back to witnesses', () => {
  class Exhausted extends fc.Arbitrary {
    generate() { throw new RangeError('custom exhausted'); }
    canShrinkWithoutContext() { return false; }
    shrink() { return fc.Stream.nil(); }
  }
  const arb = strategy(named('Int8'), [['Int8', () => new Exhausted()]], [42]);
  assert.throws(() => fc.sample(arb, 1), /custom exhausted/);
});

test('native factories can ignore empty parameters and retain shrinking', () => {
  class Phantom {
    constructor(value) { this.value = value; }
  }
  const registry = new schema.Schema([
    new schema.Definition('Empty', 0, []),
    new schema.Definition('Phantom', 1, [new schema.Constructor(
      'Phantom::Phantom', [new schema.Field('value', named('Int8'))], Phantom)]),
  ], ['Int8'], builtins);
  const type = named('Phantom', named('Empty'));
  const build = factory => generators.strategy(registry, type, 64, 32,
    () => fc.integer({min:-128,max:127}), new Map(), [], 1000,
    new Map([['Phantom',factory]]));
  const source = build(child => {
    assert.ok(child instanceof fc.Arbitrary);
    return fc.integer({min:40,max:100}).map(value => new Phantom(value));
  });
  const failed = fc.check(fc.property(source, value => value.fields[0] < 61),
    {seed:2026,numRuns:100});
  assert.equal(failed.failed,true);
  assert.equal(failed.counterexample[0].fields[0],61);
  const demanded = build(child => child.map(() => new Phantom(40)));
  assert.throws(() => fc.sample(demanded,1), /no native generator argument.*Empty/);
  assert.throws(() => generators.strategy(registry,named('Empty'),64,32,
    () => fc.integer()), /no value.*Empty|node budget/);
});
