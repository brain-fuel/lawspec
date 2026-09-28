import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const ghc = process.env.LAWSPEC_GHC;
const packageDb = process.env.LAWSPEC_GHC_PACKAGE_DB;
assert.ok(ghc && packageDb, 'Set LAWSPEC_GHC and LAWSPEC_GHC_PACKAGE_DB');
const directory = path.join(root, '.artifacts/haskell-checked-strategies');
await mkdir(directory, {recursive: true});
for (const name of ['LawSpecRuntime.hs', 'LawSpecSchema.hs', 'LawSpecDataStrategies.hs']) {
  await writeFile(path.join(directory, name), await readFile(path.join(root, 'runtime', name)));
}
await writeFile(path.join(directory, 'Main.hs'),
  await readFile(path.join(root, 'test/runtime/HaskellCheckedStrategiesCheck.hs')));
const args = ['--make', 'Main.hs', '-O0', '-i.', '-package-db', packageDb,
  '-outputdir', 'build', '-o', 'check'];
execFileSync(ghc, args, {cwd: directory, stdio: 'inherit'});
execFileSync(path.join(directory, 'check'), [], {cwd: directory, stdio: 'inherit', timeout: 30000});
const file = path.join(directory, 'LawSpecDataStrategies.hs');
const original = await readFile(file, 'utf8');
for (const [before, after] of [
  ['Gen.filterT (accepted ty) choices', 'Gen.filter (accepted ty) choices'],
  ['scoped = maybe id LS.scopeSymbols scope', 'scoped = id'],
  ['filter ((<= available) . valueNodes)', 'filter ((<= available * 100) . valueNodes)'],
  ['Left (S.Rejected _) -> False', 'Left (S.Rejected _) -> True'],
  ['Left (S.EvaluationFailure message) -> error message', 'Left (S.EvaluationFailure _) -> False'],
  ['(S.Named "List" [element], LS.SList values) -> descend element values',
    '(S.Named "List" [_], LS.SList _) -> pure indexed'],
]) {
  assert.ok(original.includes(before), before);
  try {
    await writeFile(file, original.replace(before, after));
    execFileSync(ghc, args, {cwd: directory, stdio: 'pipe'});
    const failure = spawnSync(path.join(directory, 'check'), [], {cwd: directory, encoding: 'utf8', timeout: 30000});
    assert.equal(failure.error, undefined);
    assert.notEqual(failure.status, 0, 'strategy mutant must fail');
  } finally {
    await writeFile(file, original);
  }
}
console.log('Haskell checked strategies: both profiles and six compiled mutants passed');
