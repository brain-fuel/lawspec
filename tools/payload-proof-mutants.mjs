import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {cp, mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const ghc = process.env.LAWSPEC_GHC;
const packageDb = process.env.LAWSPEC_GHC_PACKAGE_DB;
assert.ok(ghc && packageDb, 'Set LAWSPEC_GHC and LAWSPEC_GHC_PACKAGE_DB');
const directory = path.join(root, '.artifacts/payload-proof-mutants');
await mkdir(directory, {recursive: true});
await cp(path.join(root, 'src'), path.join(directory, 'src'), {recursive: true});
await cp(path.join(root, 'test/PayloadProofSpec.hs'), path.join(directory, 'PayloadProofSpec.hs'));
await writeFile(path.join(directory, 'Main.hs'),
  'import Test.Hspec\nimport qualified PayloadProofSpec\nmain = hspec PayloadProofSpec.spec\n');
const args = ['--make', 'Main.hs', '-O0', '-isrc', '-package-db', packageDb,
  '-XOverloadedStrings', '-XDeriveGeneric', '-XLambdaCase', '-XRecordWildCards',
  '-outputdir', 'build', '-o', 'check'];
const build = () => execFileSync(ghc, args, {cwd: directory, stdio: 'pipe'});
build();
execFileSync(path.join(directory, 'check'), [], {cwd: directory, stdio: 'inherit'});
for (const [name, before, after] of [
  ['Totality', '(Just a,Just b) -> a == b', '(Just _,Just _) -> True'],
  ['Totality', 'AllPayloads schema name value predicates | truth ->',
    'AllPayloads schema name value predicates | True ->'],
  ['Totality', '(value,body) <- presenceConditions facts, knownPresent facts value',
    '(value,body) <- presenceConditions facts'],
  ['Totality', 'local ++ concatMap constructorReferences (children expression)',
    'local ++ concatMap constructorReferences (case expression of AllPayloads _ _ value _ -> [value]; _ -> children expression)'],
  ['PayloadPlan', '  Constructor name arguments -> do',
    '  Constructor "Int8" [] -> pure (Parameter 0)\n  Constructor name arguments -> do'],
]) {
  const file = path.join(directory, 'src/LawSpec/Core', name + '.hs');
  const source = await readFile(file, 'utf8');
  assert.ok(source.includes(before), before);
  try {
    await writeFile(file, source.replace(before, after));
    build();
    const result = spawnSync(path.join(directory, 'check'), [],
      {cwd: directory, encoding: 'utf8', timeout: 30000});
    assert.equal(result.error, undefined);
    assert.notEqual(result.status, 0, `unsound payload proof mutant survived: ${before}`);
    assert.match(result.stdout + result.stderr, /Failures:/);
  } finally {
    await writeFile(file, source);
  }
}
console.log('Recursive payload proofs reject all five compiled unsoundness mutants');
