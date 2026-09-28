import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, mkdtemp, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {planWrites, applyWrites} from '../npm/files.mjs';

const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const fixture = process.env.LAWSPEC_HASKELL_DEFINITIONS_FIXTURE;
const ghc = process.env.LAWSPEC_GHC;
assert.ok(compiler && fixture && ghc, 'Set LAWSPEC_CORE, LAWSPEC_HASKELL_DEFINITIONS_FIXTURE and LAWSPEC_GHC');
const packageArgs = process.env.LAWSPEC_GHC_PACKAGE_DB
  ? ['-package-db', process.env.LAWSPEC_GHC_PACKAGE_DB] : [];
const source = await readFile(path.join(root, 'test/fixtures/total_definitions.lawspec'), 'utf8') + `
law \`definition Symbol shares example identity\` is
  definition is \`for all\` (x :: Unit) . symbol x = symbol("same", "description") end
end
`;
const other = `unit other
type Pair (a :: Type) (b :: Type) is Pair first :: a second :: b end
definition genericIdentity (x :: a) :: a is x end
definition genericCount (xs :: List a) :: BigInt is match xs with | Nil -> 0 | Cons head tail -> 1 + genericCount tail end end
law \`generic booleans\` is definition is \`for all\` (xs :: List Bool) . genericCount xs = prelude.length xs end end
law \`generic texts\` is definition is \`for all\` (xs :: List Text where genericCount xs > 0) . genericCount xs = prelude.length xs end end
definition size (x :: Bool) :: Bool is genericIdentity x end
definition schema (x :: Bool) :: Bool is x end
definition bits (x :: Bool) :: Bool is x end
definition pairCount (xs :: List (Pair Int8 Bool)) :: BigInt is genericCount xs end
law \`count products\` is definition is \`for all\` (xs :: List (Pair Int8 Bool)) . pairCount xs = prelude.length xs end end
`;
for (const machineBits of [32, 64]) {
  const directory = path.join(root, `.artifacts/haskell-definitions/${machineBits}`);
  const sourceDir = machineBits === 32 ? 'library/native' : 'src';
  const testDir = machineBits === 32 ? 'checks/generated' : 'test';
  const sources = [{path: 'total.lawspec', content: source}, {path: 'other.lawspec', content: other}];
  const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target: 'haskell', machineBits, sourceDir, testDir, sources,
  }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
  assert.deepEqual(result.diagnostics, []);
  const generated = [];
  const specs = [];
  let adapter;
  let adapterSource;
  for (const file of result.files) {
    assert.ok(file.path.startsWith(`${file.placement === 'test' ? testDir : sourceDir}/`));
    let content = file.content;
    if (file.ownership === 'user' && file.path.endsWith('/Example/Total.hs')) {
      assert.doesNotMatch(content, /^(size|sumList|sumTree|increment) ::/m);
      content = content.replace(/^(actual\w+) (.*?) = error "[^"]+"$/gm,
        (_, name) => `${name} value0 = ${ {
          actualSum: 'sum (map toInteger value0)',
          actualIncrement: 'toInteger value0 + 1',
          actualTree: 'case value0 of { Data.TreeLeaf x -> toInteger x; Data.TreeBranch l r -> actualTree l + actualTree r }',
        }[name]}`);
      adapter = file;
      adapterSource = content;
    }
    if (file.path.includes('LawSpecDefinition')) {
      assert.equal(file.ownership, 'generated');
      assert.equal(file.placement, 'source');
      for (const line of content.split("\n")) assert.ok(line.length <= 80, `long Haskell definition line (${line.length}): ${line}`);
      generated.push(file);
    }
    if (file.placement === 'source') assert.doesNotMatch(content, /import .*Hedgehog|import .*Hspec/);
    const destination = path.join(directory, file.path);
    await mkdir(path.dirname(destination), {recursive: true});
    await writeFile(destination, content);
    if (file.path.endsWith('Spec.hs')) specs.push(content.match(/^module (\S+)/m)[1]);
  }
  assert.equal(generated.length, 3);
  assert.ok(adapter && adapterSource);
  await writeFile(path.join(directory, 'Main.hs'), 'import Test.Hspec\n' +
    specs.map((name, i) => `import qualified ${name} as S${i}\n`).join('') +
    'main = hspec $ do\n' + specs.map((_, i) => `  S${i}.spec\n`).join(''));
  async function run(label) {
    const build = spawnSync(ghc, [...packageArgs, '--make', 'Main.hs', `-i${sourceDir}`,
      `-i${testDir}`, '-outputdir', 'build', '-o', 'check'], {cwd: directory, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024});
    await writeFile(path.join(directory, `${label}-build.log`), build.stdout + build.stderr);
    assert.equal(build.status, 0, build.stdout + build.stderr);
    const execution = spawnSync(path.join(directory, 'check'), [], {cwd: directory, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024});
    await writeFile(path.join(directory, `${label}.log`), execution.stdout + execution.stderr);
    return execution;
  }
  const correct = await run('correct');
  assert.equal(correct.status, 0, correct.stdout + correct.stderr);
  const compactPlan = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target: 'haskell', machineBits, sourceDir, testDir,
    sources, minify: true,
  }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
  assert.deepEqual(compactPlan.diagnostics, []);
  for (const file of compactPlan.files.filter(file => file.ownership === 'generated')) {
    await writeFile(path.join(directory, file.path), file.content);
  }
  const compactProperties = await run('compact-properties');
  assert.equal(compactProperties.status, 0, compactProperties.stdout + compactProperties.stderr);
  for (const file of result.files.filter(file => file.ownership === 'generated')) {
    await writeFile(path.join(directory, file.path), file.content);
  }
  for (const [label, from, to] of [
    ['sum', 'sum (map toInteger value0)', '0'],
    ['overflow', 'toInteger value0 + 1', 'toInteger (value0 + 1)'],
    ['tree', 'actualTree l + actualTree r', '0'],
  ]) {
    const changed = adapterSource.replace(from, to);
    assert.notEqual(changed, adapterSource);
    await writeFile(path.join(directory, adapter.path), changed);
    const mutant = await run(label);
    assert.notEqual(mutant.status, 0, label);
    assert.match(mutant.stdout + mutant.stderr, /Failures:|failure/);
  }
  await writeFile(path.join(directory, adapter.path), adapterSource);
  const sourcePaths = [];
  for (const item of sources) {
    const destination = path.join(directory, item.path);
    await writeFile(destination, item.content);
    sourcePaths.push(destination);
  }
  const native = path.join(directory, 'native-only');
  execFileSync(fixture, [String(machineBits), native, ...sourcePaths]);
  for (const mode of ['pretty', 'compact']) {
    const nativeRoot = path.join(native, mode);
    const nativeCheck = (await readFile(path.join(root, 'test/runtime/HaskellDefinitionsCheck.hs'), 'utf8'))
      .replace('import qualified LawSpecRuntime', 'import qualified LawSpecDefinitions.Other as Other\nimport qualified LawSpecRuntime')
      .replace('  putStrLn (', '  check "generic product and shared names" (Other.size symbols True == Right True && Other.schema symbols True == Right True && Other.bits symbols False == Right False && Other.pairCount symbols [Data.PairPair 127 True] == Right 1)\n  putStrLn (');
    await writeFile(path.join(nativeRoot, 'Main.hs'), nativeCheck);
    // No property-framework package database: generated source must stand alone.
    execFileSync(ghc, ['--make', 'Main.hs', '-i.', '-outputdir', 'build', '-o', 'check'], {cwd: nativeRoot, stdio: 'inherit'});
    execFileSync(path.join(nativeRoot, 'check'), [String(machineBits)], {cwd: nativeRoot, stdio: 'inherit'});
    for (const [i, expression] of [
      'Total.size symbols [True]', 'Total.sumTree symbols True',
      'Total.maybeDefault symbols (Just True)', 'Total.absent symbols (LS.OptionalValue True)',
    ].entries()) {
      await writeFile(path.join(nativeRoot, 'Invalid.hs'), `module Invalid where\nimport qualified LawSpecDefinitions.Example.Total as Total\nimport qualified LawSpecRuntime as LS\nbad symbols = ${expression}\n`);
      const bad = spawnSync(ghc, ['--make', 'Invalid.hs', '-i.', '-fno-code'], {cwd: nativeRoot, encoding: 'utf8'});
      await writeFile(path.join(nativeRoot, `negative-${i}.log`), bad.stdout + bad.stderr);
      assert.notEqual(bad.status, 0);
      assert.match(bad.stderr, /Couldn't match/);
    }
  }
  for (const file of generated) {
    const relative = file.path.slice(sourceDir.length + 1);
    const compact = await readFile(path.join(native, 'compact', relative), 'utf8');
    assert.ok(compact.length < file.content.length);
    await writeFile(path.join(directory, file.path), compact);
  }
  const compact = await run('compact');
  assert.equal(compact.status, 0, compact.stdout + compact.stderr);
  const regeneration = await mkdtemp(path.join(directory, 'regeneration-'));
  await applyWrites([await planWrites(regeneration, result.files)]);
  await writeFile(path.join(regeneration, adapter.path), adapterSource);
  assert.equal((await planWrites(regeneration, result.files)).changes.length, 0);
  await writeFile(path.join(regeneration, generated[0].path), '-- edited generated definition\n');
  await assert.rejects(planWrites(regeneration, result.files), /edited generated file/);
  console.log(`Haskell definitions, native types, properties, mutants, compact source and ownership passed: ${machineBits}`);
}
