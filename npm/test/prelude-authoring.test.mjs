// Generated from templates/npm/test/prelude-authoring.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile, readdir} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';

// Executable includes remain the only authored examples. Validation and law
// evidence are checked independently. ref:DEC-prelude-first-authoring
const directory = new URL('../../examples/authoring/', import.meta.url);
const compiler = await createCompiler();
const input = (sources, machineBits, layers) => ({
  languageProfile: '1.0-rc.2',
  machineBits,
  sources,
  verification: {layers},
});
test('the twelve authoring examples compile in both machine profiles', async () =>
{
  const files = (await readdir(directory)).filter(f => f.endsWith('.lawspec'));
  assert.equal(files.length, 12);
  for (const file of files)
  {
    const sources = [
      {path: file, content: await readFile(new URL(file, directory), 'utf8')},
    ];
    for (const bits of [32, 64])
    {
      const checked = await compiler.check(input(sources, bits, []));
      assert.deepEqual(checked.diagnostics, [], file);
      assert.ok(
        checked.evidence
          .filter(e => e.stage === 'law')
          .every(e => e.status === 'not-verified'),
      );
      const evaluated = await compiler.check(
        input(sources, bits, ['examples', 'exhaustive']),
      );
      assert.deepEqual(evaluated.diagnostics, [], file);
    }
  }
});
test('contrasts fail at the intended boundary', async () =>
{
  for (const [name, code] of [
    ['lost-duplicate', 'refuted'],
    ['nominal-record', 'definition'],
  ])
  {
    const sources = [
      {
        path: name,
        content: await readFile(
          new URL(`negative/${name}.lawspec`, directory),
          'utf8',
        ),
      },
    ];
    for (const bits of [32, 64])
    {
      const result = await compiler.check(
        input(sources, bits, ['exhaustive', 'examples']),
      );
      assert.deepEqual(
        result.diagnostics.map(d => d.code),
        [code],
      );
      if (name === 'lost-duplicate')
      {
        assert.deepEqual(
          (await compiler.check(input(sources, bits, []))).diagnostics,
          [],
        );
      }
    }
  }
});
