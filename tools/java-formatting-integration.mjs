// Compare untouched compiler artifacts against the independent Google Java formatter.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir, readFile, readdir, writeFile, rm} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const formatter = process.env.LAWSPEC_GOOGLE_JAVA_FORMAT;
assert.ok(compiler && formatter, 'Set LAWSPEC_CORE and LAWSPEC_GOOGLE_JAVA_FORMAT');
const paths = process.argv.slice(2).length ? process.argv.slice(2) : [
  'test/fixtures/total_definitions.lawspec',
  ...(await readdir(path.join(root, 'examples/specs'))).filter(name => name.endsWith('.lawspec'))
    .sort().map(name => `examples/specs/${name}`),
];
let checked = 0;
const mismatches = [];
const formatCache = new Map();
const artifactRoot = process.env.LAWSPEC_JAVA_FORMAT_DIR ??
  path.join(root, '.artifacts/java-formatting');
for (const source of paths) {
  const content = await readFile(path.join(root, source), 'utf8');
  for (const machineBits of [32, 64]) {
    const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
      method: 'planGeneration', target: 'java', machineBits, sources: [{path: source, content}],
    }), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024}));
    assert.deepEqual(result.diagnostics, []);
    for (const file of result.files.filter(file => file.path.endsWith('.java'))) {
      if (!formatCache.has(file.content)) {
        formatCache.set(file.content, execFileSync('java', ['-jar', formatter, '-'], {
          input: file.content, encoding: 'utf8', maxBuffer: 64 * 1024 * 1024,
        }));
      }
      const formatted = formatCache.get(file.content);
      checked++;
      const directory = path.join(artifactRoot, source, String(machineBits), path.dirname(file.path));
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
  console.log(`Checked Java formatting: ${source}`);
}
assert.deepEqual(mismatches, [], `Inspect generated/formatted snapshots in ${artifactRoot}`);
console.log(`${checked} Java artifacts match Google Java Format, including properties, in both machine profiles`);
