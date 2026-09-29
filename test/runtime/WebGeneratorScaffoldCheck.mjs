import assert from 'node:assert/strict';
import test from 'node:test';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

const extension = process.env.LAWSPEC_DATA_EXTENSION ?? 'mjs';
const load = (directory, name) => import(pathToFileURL(
  path.join(directory, `${name}.${extension}`)).href);
const [data, schema, generators, factories, fc] = await Promise.all([
  load(process.env.LAWSPEC_DATA_DIR, 'lawspec_data'),
  load(process.env.LAWSPEC_DATA_DIR, 'lawspec_schema'),
  load(process.env.LAWSPEC_STRATEGIES_DIR, 'lawspec_native_generators'),
  load(process.env.LAWSPEC_STRATEGIES_DIR, 'factories/lawspec_generators'),
  import(pathToFileURL(process.env.LAWSPEC_FAST_CHECK).href),
]);

test('implemented generic scaffold composes the native child arbitrary', () => {
  const before = factories.listFactories;
  const arbitrary = generators.strategy(data.makeSchema(),
    new schema.Named('List', [new schema.Named('example.payments::type::Money')]),
    64, 64, () => { throw new Error('custom factories must supply values'); });
  assert.ok(factories.listFactories > before);
  const result = fc.check(fc.property(arbitrary, values => values.length < 2),
    {seed:2026, numRuns:100});
  assert.equal(result.failed, true);
  assert.equal(result.counterexample[0].length, 2);
  for (const price of result.counterexample[0]) {
    assert.equal(price.fields[0].coefficient, 100n);
    assert.equal(price.fields[0].exponent, -2n);
  }
});
