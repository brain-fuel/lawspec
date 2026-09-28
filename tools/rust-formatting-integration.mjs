// Compare untouched compiler artifacts against the independent Rust formatter.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir, readFile, readdir, writeFile, rm} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
assert.ok(compiler, 'Set LAWSPEC_CORE');
const paths = process.argv.slice(2).length ? process.argv.slice(2) : [
  'test/fixtures/total_definitions.lawspec',
  ...(await readdir(path.join(root, 'examples/specs'))).filter(name => name.endsWith('.lawspec'))
    .sort().map(name => `examples/specs/${name}`),
];
let checked = 0;
const mismatches = [];
for (const source of paths) {
  const content = await readFile(path.join(root, source), 'utf8');
  for (const machineBits of [32, 64]) {
    const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
      method: 'planGeneration', target: 'rust', machineBits, sources: [{path: source, content}],
    }), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024}));
    assert.deepEqual(result.diagnostics, []);
    for (const file of result.files.filter(file => file.path.endsWith('.rs'))) {
      const formatted = execFileSync('rustfmt', ['--edition', '2024', '--config', 'skip_children=true'], {
        input: file.content, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024,
      });
      checked++;
      const directory = path.join(root, '.artifacts/rust-formatting', source, String(machineBits), path.dirname(file.path));
      const originalPath = path.join(directory, path.basename(file.path) + '.generated');
      const formattedPath = path.join(directory, path.basename(file.path) + '.formatted');
      if (file.content !== formatted) {
        await mkdir(directory, {recursive: true});
        await writeFile(originalPath, file.content);
        await writeFile(formattedPath, formatted);
        mismatches.push(`${source}/${machineBits}/${file.path}`);
      } else {
        await Promise.all([rm(originalPath, {force: true}), rm(formattedPath, {force: true})]);
      }
    }
  }
}
assert.deepEqual(mismatches, [], 'Inspect generated/formatted snapshots in .artifacts/rust-formatting');
console.log(`${checked} Rust artifacts match rustfmt, including properties, in both machine profiles`);
