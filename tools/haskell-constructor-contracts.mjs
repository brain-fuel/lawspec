import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const ghc = process.env.LAWSPEC_GHC;
assert.ok(ghc, 'Set LAWSPEC_GHC');
const directory = path.join(root, '.artifacts/haskell-constructor-contracts');
await mkdir(directory, {recursive: true});
for (const name of ['LawSpecRuntime.hs', 'LawSpecSchema.hs']) {
  await writeFile(path.join(directory, name), await readFile(path.join(root, 'runtime', name)));
}
await writeFile(path.join(directory, 'Main.hs'),
  await readFile(path.join(root, 'test/runtime/HaskellConstructorContractsCheck.hs')));
const args = ['--make', 'Main.hs', '-O0', '-i.', '-outputdir', 'build', '-o', 'check'];
if (process.env.LAWSPEC_GHC_PACKAGE_DB) args.push('-package-db', process.env.LAWSPEC_GHC_PACKAGE_DB);
execFileSync(ghc, args, {cwd: directory, stdio: 'inherit'});
execFileSync(path.join(directory, 'check'), [], {cwd: directory, stdio: 'inherit'});
const file = path.join(directory, 'LawSpecSchema.hs');
const source = await readFile(file, 'utf8');
for (const [before, after] of [
  ['unless accepted', 'unless (accepted || True)'],
  ['(validateChecked scope schema element bits child)', '(validateChecked Nothing schema element bits child)'],
  ['fromEvaluation = either (Left . EvaluationFailure)', 'fromEvaluation = either (Left . Rejected)'],
  ['zip [1 :: Int ..] predicates', 'zip [1 :: Int ..] (reverse predicates)'],
]) {
  assert.ok(source.includes(before), before);
  try {
    await writeFile(file, source.replace(before, after));
    execFileSync(ghc, args, {cwd: directory, stdio: 'pipe'});
    const failure = spawnSync(path.join(directory, 'check'), [], {cwd: directory, encoding: 'utf8'});
    assert.notEqual(failure.status, 0, 'mutant must fail execution');
  } finally {
    await writeFile(file, source);
  }
}
console.log('Haskell constructor runtime: both widths and four compiled mutants passed');
