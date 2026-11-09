// Generated from templates/npm/test/manifest-codec-reference.test.mjs by lawspec-dev generate. Do not edit.
// Frozen compatibility evidence for the Haskell application port.
// ref:DEC-haskell-application-port ref:REQ-compiler-api-contract
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {parseManifest, writeManifest} from '../component.mjs';
import * as reference from './reference/manifest-codec.mjs';

const fixture = JSON.parse(
  await readFile(
    new URL(
      '../../test/fixtures/application-port/manifest-codec.json',
      import.meta.url,
    ),
    'utf8',
  ),
);
test('manifest reference retains its recorded source and dependency bytes', async () =>
{
  const inputs = [
    [
      new URL(
        '../../templates/npm/test/reference/manifest-codec.mjs',
        import.meta.url,
      ),
      fixture.referenceTemplateSha256,
    ],
    ...['parse', 'generate'].map(name => [
      new URL(`../node_modules/edn-data/dist/${name}.js`, import.meta.url),
      fixture.sources[`npm/node_modules/edn-data/dist/${name}.js`],
    ]),
  ];
  for (const [file, digest] of inputs)
  {
    const bytes = await readFile(file);
    assert.equal(createHash('sha256').update(bytes).digest('hex'), digest);
  }
});

for (const candidate of [reference, {parseManifest, writeManifest}])
{
  const label = candidate === reference ? 'frozen reference' : 'public codec';
  for (const entry of fixture.cases)
  {
    test(`${label}: ${entry.name}`, () =>
    {
      if (Object.hasOwn(entry, 'error'))
      {
        assert.throws(
          () => candidate.parseManifest(entry.input),
          error =>
          {
            assert.deepEqual(error.diagnostics, [
              {code: 'manifest', message: entry.error},
            ]);
            return true;
          },
        );
        assert.throws(
          () => candidate.parseManifest(entry.input, 'λ.edn'),
          error =>
          {
            assert.equal(error.message, `λ.edn: ${entry.error}`);
            assert.deepEqual(error.diagnostics, [
              {
                code: 'manifest',
                message: entry.error,
                at: {file: 'λ.edn', line: 1, column: 1},
              },
            ]);
            return true;
          },
        );
      }
      else
      {
        const value = candidate.parseManifest(entry.input);
        // JSON records deliberately normalize negative zero, as the public wire
        // codec does. Writer-byte comparisons below retain its observable form.
        assert.equal(JSON.stringify(value), entry.json);
        assert.equal(candidate.writeManifest(value), entry.readable);
        assert.equal(
          candidate.writeManifest(value, {compact: true}),
          entry.compact,
        );
      }
    });
  }
}
