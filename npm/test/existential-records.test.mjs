// Generated from templates/npm/test/existential-records.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';
import {programTargets as targets} from '../templates.mjs';
const compiler = await createCompiler();
const options = {
  schemaVersion: 5,
  languageProfile: '1.0-rc.2',
  verification: {layers: []},
};

test('existential record factories format idempotently and generate on every target, width and layout', async () =>
{
  const content = await readFile(
    new URL(
      '../../test/fixtures/canonical-existential-records.lawspec',
      import.meta.url,
    ),
    'utf8',
  );
  const sources = [{path: 'existential.lawspec', content}];
  const formatted = await compiler.format({...options, sources});
  assert.deepEqual(formatted.diagnostics, []);
  assert.deepEqual(
    (await compiler.format({...options, sources: formatted.formattedSources}))
      .formattedSources,
    formatted.formattedSources,
  );
  for (const target of targets)
    for (const machineBits of [32, 64])
      for (const minify of [false, true])
      {
        const result = await compiler.planGeneration({
          ...options,
          target,
          machineBits,
          minify,
          sources: formatted.formattedSources,
        });
        assert.deepEqual(
          result.diagnostics,
          [],
          `${target}/${machineBits}/${minify}`,
        );
        assert.ok(result.files.some(file => file.placement === 'source'));
        assert.equal(result.verification.intrinsicDefinitionChecks, true);
      }
});
