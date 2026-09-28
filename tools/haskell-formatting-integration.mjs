// Independent GHC parsing/AST parity and an explicit 80-column source audit.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir, readFile, readdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const checker = process.env.LAWSPEC_HASKELL_SYNTAX_CHECK;
const ghc = process.env.LAWSPEC_GHC;
assert.ok(compiler && checker && ghc, 'Set LAWSPEC_CORE, LAWSPEC_HASKELL_SYNTAX_CHECK and LAWSPEC_GHC');
const syntaxOnly = process.argv.includes('--syntax-only');
const requested = process.argv.slice(2).filter(arg => arg !== '--syntax-only');
const specs = requested.length ? requested : [
  'test/fixtures/total_definitions.lawspec',
  ...(await readdir(path.join(root, 'examples/specs'))).filter(name => name.endsWith('.lawspec'))
    .sort().map(name => `examples/specs/${name}`),
];
const directory = process.env.LAWSPEC_HASKELL_FORMAT_DIR ??
  path.join(root, '.artifacts/haskell-formatting');
await mkdir(directory, {recursive: true});
const pairs = [];
const failures = [];
const unique = new Map();
let count = 0;
for (const spec of specs) for (const machineBits of [32, 64]) {
  const content = await readFile(path.join(root, spec), 'utf8');
  const generate = minify => {
    const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
      method: 'planGeneration', target: 'haskell', machineBits, minify,
      sources: [{path: spec, content}],
    }), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024}));
    assert.deepEqual(result.diagnostics, [], spec);
    return result.files.filter(file => file.path.endsWith('.hs'));
  };
  const readable = generate(false);
  const compact = generate(true);
  assert.deepEqual(readable.map(file => file.path), compact.map(file => file.path));
  for (const [index, file] of readable.entries()) {
    count++;
    const label = `${spec}/${machineBits}/${file.path}`;
    const key = JSON.stringify([file.content, compact[index].content]);
    if (!unique.has(key)) {
      const prefix = path.join(directory, String(unique.size));
      const paths = [prefix + '.hs', prefix + '.compact.hs'];
      await writeFile(paths[0], file.content);
      await writeFile(paths[1], compact[index].content);
      unique.set(key, paths);
      pairs.push(paths);
    }
    for (const [line, text] of file.content.split('\n').entries()) {
      if ([...text].length > 80 || /[ \t]+$|\t/.test(text)) {
        failures.push({label, line: line + 1, text});
      }
    }
  }
}
await writeFile(path.join(directory, 'style-report.json'), JSON.stringify(failures, null, 2) + '\n');
await writeFile(path.join(directory, 'pairs.json'), JSON.stringify(pairs, null, 2) + '\n');
const libdir = execFileSync(ghc, ['--print-libdir'], {encoding: 'utf8'}).trim();
const log = execFileSync(checker, [libdir], {input: JSON.stringify(pairs), encoding: 'utf8',
  maxBuffer: 8 * 1024 * 1024});
process.stdout.write(log);
if (!syntaxOnly) assert.equal(failures.length, 0, 'See .artifacts/haskell-formatting/style-report.json');
console.log(`${count} Haskell artifacts pass GHC parsing and syntax-tree parity; ` +
  (syntaxOnly ? `${failures.length} style violations recorded (syntax-only audit)` : '80-column style audit passes'));
