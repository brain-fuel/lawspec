// Generated from templates/npm/test/documentation-manifests.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile, readdir, mkdtemp, writeFile, rm} from 'node:fs/promises';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {parseManifest, readManifest} from '../component.mjs';

// Documentation is checked against the compiler-owned manifest schema, rather
// than a second test-only list of current fields or a version-string snapshot.
test('complete documentation manifest examples satisfy the current compiler schema', async () =>
{
  const root = new URL('../../docs/', import.meta.url);
  const files = await readdir(root, {recursive: true});
  const directory = await mkdtemp(
    path.join(tmpdir(), 'lawspec-doc-manifests-'),
  );
  let count = 0;
  try
  {
    for (const file of files.filter(file => file.endsWith('.md')))
    {
      const source = await readFile(new URL(file, root), 'utf8');
      for (const [index, block] of [
        ...source.matchAll(/```edn\n([\s\S]*?)\n```/g),
      ].entries())
      {
        const value = parseManifest(block[1], file);
        if (value.manifestVersion === undefined && value.sources === undefined)
          continue;
        const manifest = path.join(directory, 'lawspec.edn');
        await writeFile(manifest, block[1]);
        try
        {
          await readManifest(manifest);
        }
        catch (error)
        {
          assert.fail(`${file}, EDN example ${index + 1}: ${error.message}`);
        }
        count++;
      }
    }
    assert.ok(count >= 7, 'the guide examples must be discovered');
  }
  finally
  {
    await rm(directory, {recursive: true, force: true});
  }
});
