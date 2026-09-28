import assert from 'node:assert/strict';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

const root = process.env.LAWSPEC_DATA_DIR;
const extension = process.env.LAWSPEC_DATA_EXTENSION ?? 'mjs';
const load = name => import(pathToFileURL(path.join(root,
  `${name}.${extension}`)).href);
const [data, ls, schema, fields] = await Promise.all([
  load('lawspec_data'), load('lawspec_runtime'), load('lawspec_schema'),
  load('lawspec_definitions/native/fields'),
]);
const bits = Number(process.env.LAWSPEC_MACHINE_BITS);
const fresh = () => new Map();
const rejected = action => assert.throws(action, /field refinement/);
assert.deepEqual(fields.inverseGap(fresh(), new data.GapGap(-128, 127)),
  new ls.Rational(1n, 255n));
rejected(() => fields.inverseGap(fresh(), new data.GapGap(127, -128)));
rejected(() => fields.inverseGap(fresh(), new data.GapGap(0, 0)));
assert.deepEqual(fields.echoBucket(fresh(), new data.BucketBucket([1])).values, [1]);
rejected(() => fields.echoBucket(fresh(), new data.BucketBucket([])));
assert.deepEqual(fields.echoPositives(fresh(),
  new data.PositivesPositives([1, 2])).values, [1, 2]);
rejected(() => fields.echoPositives(fresh(), new data.PositivesPositives([0])));
assert.equal(fields.echoChoice(fresh(), new data.ChoiceRejected('no')).reason, 'no');
assert.equal(fields.echoChoice(fresh(), new data.ChoiceAccepted(1)).value, 1);
rejected(() => fields.echoChoice(fresh(), new data.ChoiceAccepted(0)));
assert.equal(fields.echoGuarded(fresh(), new data.GuardedGuarded(2)).value, 2);
rejected(() => fields.echoGuarded(fresh(), new data.GuardedGuarded(0)));
rejected(() => fields.echoGuarded(fresh(), new data.GuardedGuarded(-1)));
assert.equal(fields.echoMachine(fresh(), new data.MachineMachine(1n)).value, 1n);
rejected(() => fields.echoMachine(fresh(), new data.MachineMachine(0n)));
if (bits === 64) {
  assert.equal(fields.echoMachine(fresh(),
    new data.MachineMachine(2n ** 40n)).value, 2n ** 40n);
} else {
  assert.throws(() => fields.echoMachine(fresh(),
    new data.MachineMachine(2n ** 40n)), /IntSize/);
}
const symbols = fresh();
const expected = ls.literal({type: 'Symbol', id: 'fixture', description: 'same'},
  symbols);
assert.equal(fields.echoIdentity(symbols, new data.IdentityIdentity(expected)).value,
  expected);
rejected(() => fields.echoIdentity(symbols, new data.IdentityIdentity(Symbol('same'))));
rejected(() => fields.echoIdentity(fresh(), new data.IdentityIdentity(expected)));
const registry = data.makeSchema();
const type = new schema.Named('List', [new schema.Named('native.fields::type::Identity')]);
const logical = registry.fromNative(type, [new data.IdentityIdentity(expected)], bits,
  symbols);
assert.equal(registry.equal(type, logical, logical, bits, symbols), true);
assert.equal(registry.toNative(type, logical, bits, symbols)[0].value, expected);
assert.equal(schema.typeKey(new schema.Named('Either', [
  new schema.Named('List', [new schema.Named('Int8')]), new schema.Named('Text'),
])), 'Either (List Int8) (Text)');
console.log(`Generated web constructor predicates and native APIs passed: ${bits}`);

// Native definition checks above do not need fast-check. Generator integration
// loads the test-only runtime separately and uses the same fixture context.
if (process.env.LAWSPEC_FAST_CHECK) {
  const [fc, generators] = await Promise.all([
    import(pathToFileURL(process.env.LAWSPEC_FAST_CHECK).href),
    load('lawspec_data_strategies'),
  ]);
  const arbitrary = generators.strategy(registry, type, bits, 7,
    () => fc.string().map(value => Symbol(value)), symbols, [logical]);
  const result = fc.check(fc.property(arbitrary, values => {
    for (const value of registry.toNative(type, values, bits, symbols)) {
      assert.equal(fields.echoIdentity(symbols, value).value, expected);
    }
    return values.length !== 3;
  }), {seed: 424242, numRuns: 100});
  assert.ok(result.failed);
  assert.equal(result.counterexample[0].length, 3);
  console.log(`Generated web witness strategies passed: ${bits}`);
}
