/** Template formatting must preserve every placeholder identity, including 1/10 prefixes. ref:REQ-google-style-allman */
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {fileURLToPath} from 'node:url';
const formatter = fileURLToPath(
  new URL('../../templates/tools/code-style.mjs', import.meta.url),
);
test('formatting templates preserves distinct holes and reaches a fixed point', async () =>
{
  const directory = await mkdtemp(path.join(os.tmpdir(), 'lawspec-style-'));
  try
  {
    const file = path.join(directory, 'adapter.mjs');
    const holes = Array.from(
      {length: 24},
      (_, index) => '@@Type' + index + '@@',
    );
    await writeFile(
      file,
      holes
        .map(
          (hole, index) =>
            `export function value${index}(){return new ${hole}("braces { stay literal }");}`,
        )
        .join('\n'),
    );
    execFileSync(process.execPath, [formatter, file]);
    const formatted = await readFile(file, 'utf8');
    assert.deepEqual(formatted.match(/@@[^@\n]+@@/g), holes);
    assert.match(formatted, /\n\{\n/);
    assert.match(formatted, /braces \{ stay literal \}/);
    execFileSync(process.execPath, [formatter, '--check', file]);
    assert.equal(await readFile(file, 'utf8'), formatted);
  }
  finally
  {
    await rm(directory, {recursive: true, force: true});
  }
});
