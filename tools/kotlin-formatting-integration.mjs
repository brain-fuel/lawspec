// Parse all generated Kotlin with an independently installed Kotlin compiler.
import assert from 'node:assert/strict';
import {templates} from '../npm/templates.mjs';
import {execFileSync} from 'node:child_process';
import {access, mkdir, readFile, readdir, realpath, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
assert.ok(compiler, 'Set LAWSPEC_CORE');
let home = process.env.LAWSPEC_KOTLIN_HOME ?? path.dirname(path.dirname(
  await realpath(execFileSync('which', ['kotlinc'], {encoding: 'utf8'}).trim())));
if (!process.env.LAWSPEC_KOTLIN_HOME &&
    !await access(path.join(home, 'lib/kotlin-compiler.jar')).then(() => true, () => false))
  home = path.join(home, 'libexec');
const directory = path.join(root, '.artifacts/kotlin-format-check');
await mkdir(directory, {recursive: true});
execFileSync('javac', ['-cp', path.join(home, 'lib/*'), '-d', directory,
  path.join(root, 'tools/KotlinFormatCheck.java')], {stdio: 'inherit'});
const specs = process.argv.slice(2).length ? process.argv.slice(2) : [
  'test/fixtures/total_definitions.lawspec',
  ...(await readdir(path.join(root, 'examples/specs'))).filter(name => name.endsWith('.lawspec'))
    .sort().map(name => `examples/specs/${name}`),
];
const rows = [];
let index = 0;
for (const source of specs) {
  const content = await readFile(path.resolve(root, source), 'utf8');
  for (const machineBits of [32, 64]) {
    const generate = minify => {
      const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
        method: 'planGeneration', target: 'kotlin', machineBits, minify,
        sources: [{path: source, content}],
      }), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024}));
      assert.deepEqual(result.diagnostics, [], source);
      return result.files.filter(file => file.path.endsWith('.kt'));
    };
    const readable = generate(false);
    const compact = generate(true);
    assert.deepEqual(readable.map(file => file.path), compact.map(file => file.path));
    for (const [item, file] of readable.entries()) {
      const prefix = path.join(directory, String(index++));
      await writeFile(prefix + '.kt', file.content);
      await writeFile(prefix + '.compact.kt', compact[item].content);
      rows.push([prefix + '.kt', prefix + '.compact.kt', `${source}/${machineBits}/${file.path}`].join('\t'));
    }
  }
}
const scaffolds = templates('kotlin');
const compactScaffolds = templates('kotlin', {minify: true});
for (const [name, content] of Object.entries(scaffolds)) {
  if (!name.endsWith('.kts')) continue;
  const prefix = path.join(directory, String(index++));
  await writeFile(prefix + '.kt', content);
  await writeFile(prefix + '.compact.kt', compactScaffolds[name]);
  rows.push([prefix + '.kt', prefix + '.compact.kt', `scaffolds/${name}`].join('\t'));
}
const manifest = path.join(directory, 'manifest.tsv');
await writeFile(manifest, rows.join('\n') + '\n');
execFileSync('java', ['-cp', directory + path.delimiter + path.join(home, 'lib/*'),
  'KotlinFormatCheck', manifest], {stdio: 'inherit'});
