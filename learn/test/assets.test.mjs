/** @file Check the course contract with actual execution and negative controls. ref:REQ-learn-local-execution */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
test('the packaged browser compiler, metadata and runtime library use the agreed independent pins', async () =>
{
  const root = new URL('../../npm/learn/vendor/', import.meta.url);
  const manifest = JSON.parse(await readFile(new URL('manifest.json', root)));
  assert.equal(manifest.fable, '5.21.0');
  for (const [name, version] of Object.entries({
    '@fable-org/fable-standalone': '3.7.2',
    '@fable-org/fable-metadata': '2.2.0',
    '@fable-org/fable-library-js': '2.2.0',
    typescript: '5.9.3',
    'monaco-editor': '0.57.0',
    'esbuild-wasm': '0.28.2',
    'fast-check': '4.10.2',
  }))
  {
    assert.equal(manifest.versions[name], version, name);
  }
  const library = JSON.parse(
    await readFile(new URL('fable-library/package.json', root)),
  );
  assert.equal(library.version, '2.2.0');
});
test('virtual imports cannot turn source text into an asset request or filesystem path', async () =>
{
  const {packagedReader} = await import('../browser/assets.mjs');
  const requests = [];
  const read = packagedReader(
    {assets: {'fable-library/List.js': {}}},
    async name =>
    {
      requests.push(name);
      return 'known asset';
    },
  );
  assert.equal(await read('fable-library/List.js'), 'known asset');
  for (const name of [
    'fable-library/List.js?source=private-code',
    'fable-library/../../outside.js',
    'https://example.invalid/private-code',
    '//example.invalid/code',
  ])
  {
    await assert.rejects(read(name), /Unsupported packaged import/);
  }
  assert.deepEqual(requests, ['fable-library/List.js']);
});
