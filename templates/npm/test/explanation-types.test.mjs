import {extendUnit} from './compiler-input.mjs';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { explanations, explanationText } from './compiler-input.mjs';

// Type presentation rules for synthetic declarations: test/ExplainSpec.hs.

test('actual checked parcel domains show field names and refinements without altering obligations or evidence', async () => {
  const { createCompiler } = await import('../api.mjs');
  const compiler = await createCompiler();
  const content = await readFile(new URL('../../examples/rc1/parcel-measurements.lawspec', import.meta.url), 'utf8');
  const request = { schemaVersion: 5, languageProfile: '1.0-rc.2', verification: { layers: [] },
    sources: [{ path: 'parcel-measurements.lawspec', content }] };
  const result = await compiler.check(request);
  assert.deepEqual(result.diagnostics, []);
  const law = result.laws.find(law => law.id.endsWith('::positiveWeights'));
  assert.ok(law);
  const shown = {};
  for (const view of ['eng', 'math', 'dev']) {
    shown[view] = explanationText((await explanations(compiler, request, view)).find(e => e.law === law.id));
    assert.doesNotMatch(shown[view], /lawspec::structural|lawspecRecordView/);
  }
  assert.match(shown.dev, /parcel of type record\{weight of type \(weight of type Measurement Integer where \(weight\.reading\.value > 0\)\)\}/);
  assert.match(shown.eng, /For every parcel \(a record with weight \(Measurement of integer where the value of the reading of weight is greater than 0\)\)/);
  assert.match(shown.eng, /The weight of this parcel must be greater than 0\./);
  assert.match(shown.math, /∀ parcel ∈ ⟨weight: \{weight ∈ Measurement ℤ \| weight\.reading\.value > 0\}⟩\.\n  weightOf\(parcel\) > 0$/);
  assert.deepEqual((await compiler.check(request)).evidence, result.evidence);
  const [developer] = await explanations(compiler, request, 'dev', law.owner + '::' + law.name);
  const displayedType = developer.sections.find(section => section.kind === 'inputs').lines[0].replace(/^Inputs: parcel of type /, '');
  const roundtrip = await compiler.check({ schemaVersion: 5, languageProfile: '1.0-rc.2', verification: { layers: [] },
    sources: [{ path: 'parcel-measurements.lawspec', content: extendUnit(content,
      `\nfunction domainIdentity (value of type ${displayedType}) -> ${displayedType} is\n  value\nend function\n`) }] });
  assert.deepEqual(roundtrip.diagnostics, []);
  const identity = roundtrip.definitions.find(d => d.id.endsWith('::domainIdentity'));
  assert.ok(identity);
  assert.deepEqual(identity.arguments[0].type, law.inputs[0].type);
  assert.deepEqual(identity.body.type, law.inputs[0].type);
  assert.equal(roundtrip.dataTypes.find(d => d.id === identity.arguments[0].type.name).structure.descriptor,
    result.dataTypes.find(d => d.id === law.inputs[0].type.name).structure.descriptor);
});
