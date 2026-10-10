// Generated from templates/npm/test/build-files.test.mjs by lawspec-dev generate. Do not edit.
// Generation never rewrites project build files, and regenerating is a no-op.
// This replaces the build-file guard formerly in tools/integration.mjs; the
// generated projects themselves are exercised by lawspec-acceptance.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, readFile, rm, writeFile} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createCompiler} from '../api.mjs';
import {planWrites, applyWrites} from '../files.mjs';
import {templates, targets} from '../templates.mjs';

const compiler = await createCompiler();
const sources = await Promise.all(['atoi_codec', 'algebra', 'currying', 'slug'].map(async name => ({
  path: `${name}.lawspec`,
  content: await readFile(new URL(`../examples/specs/${name}.lawspec`, import.meta.url), 'utf8'),
})));

for (const target of targets) {
  test(`${target}: generation preserves scaffold build files and is idempotent`, async t => {
    const root = await mkdtemp(path.join(os.tmpdir(), `lawspec-build-files-${target}-`));
    t.after(() => rm(root, {recursive: true, force: true}));
    const scaffold = Object.entries(templates(target));
    for (const [file, content] of scaffold) {
      await mkdir(path.dirname(path.join(root, file)), {recursive: true});
      await writeFile(path.join(root, file), content);
    }
    const result = await compiler.planGeneration({sources, target});
    assert.deepEqual(result.diagnostics, []);
    await applyWrites([await planWrites(root, result.files)]);
    for (const [file, content] of scaffold) {
      assert.equal(await readFile(path.join(root, file), 'utf8'), content, `${file} changed`);
    }
    assert.equal((await planWrites(root, result.files)).changes.length, 0);
  });
}
