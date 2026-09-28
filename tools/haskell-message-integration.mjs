// Native checks independent of the emitter's string escaping and chunking.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const ghc = process.env.LAWSPEC_GHC;
assert.ok(compiler && ghc, 'Set LAWSPEC_CORE and LAWSPEC_GHC');
const packageArgs = process.env.LAWSPEC_GHC_PACKAGE_DB ? ['-package-db', process.env.LAWSPEC_GHC_PACKAGE_DB] : [];
const label = 'long diagnostic: repeated spaces   quotes " apostrophes \' backslashes \\ dollars $ and supplementary Unicode 🙂 must remain exact';
const payload = 'fixture: repeated spaces   tabs\t newlines\n quotes " backslashes \\ and supplementary 🙂 ' + '🙂'.repeat(40);
const integers = [-(2n ** 127n) - 1n, -(2n ** 127n), 2n ** 127n - 1n, 2n ** 127n, -(2n ** 256n), 2n ** 256n];
const source = `unit diagnostic
echo :: Text -> Text
parseInteger :: Text -> BigInt
law \`${label}\` is
  definition is \`for all\` (x :: Text) . echo x = x end
  example \`literal\` is x = ${JSON.stringify(payload)} expect echo x = ${JSON.stringify(payload)} end
end
${integers.map((value, i) => `law \`integer representation ${i}\` is
definition is \`for all\` (marker :: Unit) . parseInteger "${value}" = ${value} end end`).join('\n')}`;
// Expected native strings use numeric code points, bypassing generated quoting.
const nativeString = value => `T.pack (map chr [${[...value].map(c => c.codePointAt(0)).join(',')}])`;
for (const minify of [false, true]) {
  const directory = path.join(root, '.artifacts/haskell-messages', minify ? 'compact' : 'readable');
  const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target: 'haskell', minify, sources: [{path: 'diagnostic', content: source}],
  }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
  assert.deepEqual(result.diagnostics, []);
  for (const file of result.files) {
    const destination = path.join(directory, file.path);
    await mkdir(path.dirname(destination), {recursive: true});
    await writeFile(destination, file.content);
  }
  const adapter = result.files.find(file => file.ownership === 'user');
  const adapterPath = path.join(directory, adapter.path);
  const body = `module Diagnostic where
import qualified Data.Text as T
import Data.Char (chr)
echo :: T.Text -> T.Text
echo value
  | T.pack "fixture:" \`T.isPrefixOf\` value && value /= ${nativeString(payload)} = error "changed fixture"
  | otherwise = value
parseInteger :: T.Text -> Integer
parseInteger value = case lookup value [${integers.map(n => `(${nativeString(String(n))}, (${n}))`).join(',')}] of
  Just result -> result
  Nothing -> error "changed integer text"
`;
  await writeFile(adapterPath, body);
  await writeFile(path.join(directory, 'Main.hs'), 'import Test.Hspec\nimport qualified DiagnosticSpec\nmain = hspec DiagnosticSpec.spec\n');
  async function run(name, args = []) {
    const build = spawnSync(ghc, [...packageArgs, '--make', 'Main.hs', '-isrc', '-itest', '-O0', '-outputdir', 'build', '-o', 'check'], {cwd: directory, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024});
    await writeFile(path.join(directory, `${name}-build.log`), build.stdout + build.stderr);
    assert.equal(build.status, 0, build.stdout + build.stderr);
    const execution = spawnSync(path.join(directory, 'check'), args, {cwd: directory, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024});
    await writeFile(path.join(directory, `${name}.log`), execution.stdout + execution.stderr);
    return execution;
  }
  const correct = await run('correct');
  assert.equal(correct.status, 0, correct.stdout + correct.stderr);
  await writeFile(adapterPath, body.replace('| otherwise = value', '| otherwise = T.snoc value \'!\''));
  try {
    const failure = await run('context', ['--match', 'law0Boundary0']);
    assert.notEqual(failure.status, 0);
    const expected = `diagnostic::${label} boundary 0 | expect echo (_input0) = _input0`;
    assert.ok(failure.stdout.includes(expected), failure.stdout + failure.stderr);
    assert.match(failure.stdout, /1 example, 1 failure/);
  } finally { await writeFile(adapterPath, body); }
  const generated = result.files.find(file => file.path.endsWith('DiagnosticSpec.hs')).content;
  if (!minify) {
    // Metadata retains unbroken source tokens and URLs; executable literals wrap.
    const longLines = generated.split('\n').filter(line => !line.trimStart().startsWith('--') && line.length > 80);
    assert.deepEqual(longLines, [], 'long diagnostic fixtures must wrap at 80 columns');
  }
  console.log(`Haskell ${minify ? 'compact' : 'readable'}: exact integers, literals and diagnostics preserved`);
}
