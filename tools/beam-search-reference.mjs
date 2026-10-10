// Generated from templates/tools/beam-search-reference.mjs by lawspec-dev generate. Do not edit.
// Actual candidates from the existing portable descriptor climb.
// ref:REQ-harness-units ref:DEC-tests-cite-requirements
import { writeFile } from 'node:fs/promises';
import { DataValue, render, searchClimb } from '../runtime/lawspec_runtime.mjs';

const score = (value) => {
  if (typeof value === 'bigint') return -(value - 37n) * (value - 37n);
  if (Array.isArray(value)) return value.reduce((n, v) => n + score(v), 0n);
  if (value instanceof DataValue) return score(value.fields);
  return 0n;
};
const descriptors = [
  ['(int Int32 0 1000)'],
  ['(int Int32 -1000 1000)', '(int BigUInt 0 _)'],
  ['(list (maybe (int Int8 -128 127)))'],
  ['(data Box (ctor Box::Box (either (int Int16 -32768 32767) (list (int Int8 -128 127))))) (ref Box)'],
  ['(data Tree (ctor Tree::Leaf (int Int8 -128 127)) (ctor Tree::Fork (ref Tree) (ref Tree))) (ref Tree)'],
];
const cases = [];
for (const seed of ['0', '42', '-1', '18446744073709551617']) {
  for (const [i, ds] of descriptors.entries()) {
    process.env.LAWSPEC_SEED = seed;
    const tried = [];
    const label = `search-${i}-${seed}`;
    await searchClimb(label, ds, (values) => {
      tried.push(render(values));
      return score(values);
    });
    cases.push({ label, seed, descriptors: ds, tried });
  }
}
await writeFile(process.argv[2], JSON.stringify(cases));
