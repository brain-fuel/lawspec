import assert from 'node:assert/strict';
import test from 'node:test';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

const extension = process.env.LAWSPEC_DATA_EXTENSION ?? 'mjs';
const load = (directory, name) => import(pathToFileURL(
  path.join(directory, `${name}.${extension}`)).href);
const [data, schema, generators, fc] = await Promise.all([
  load(process.env.LAWSPEC_DATA_DIR, 'lawspec_data'),
  load(process.env.LAWSPEC_DATA_DIR, 'lawspec_schema'),
  load(process.env.LAWSPEC_STRATEGIES_DIR, 'lawspec_native_generators'),
  import(pathToFileURL(process.env.LAWSPEC_FAST_CHECK).href),
]);

test('emitted application Money factory retains its shrinker', () => {
  const arbitrary = generators.strategy(data.makeSchema(),
    new schema.Named('example.payments::type::Money'), 64, 64,
    () => { throw new Error('custom Money factory must supply its values'); });
  const result = fc.check(fc.property(arbitrary, value => {
    assert.equal(value.fields[1].tag, 'example.payments::type::Currency::EUR');
    return value.fields[0].coefficient < 161n;
  }), {seed:2026, numRuns:100});
  assert.equal(result.failed, true);
  assert.equal(result.counterexample[0].fields[0].coefficient, 161n);
  assert.equal(result.counterexample[0].fields[0].exponent, -2n);
});
