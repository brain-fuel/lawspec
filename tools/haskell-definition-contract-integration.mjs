import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_HASKELL_CONTRACT_FIXTURE;
const ghc = process.env.LAWSPEC_GHC;
assert.ok(fixture && ghc, 'Set LAWSPEC_HASKELL_CONTRACT_FIXTURE and LAWSPEC_GHC');
const base = path.join(root, `.artifacts/haskell-definition-contracts${process.env.LAWSPEC_CONTRACT_SOURCE === '1' ? '-source' : ''}`);
execFileSync(fixture, [base]);
const source = `module Main where
import Control.Monad (unless)
import Data.List (isInfixOf)
import Data.Ratio ((%))
import System.Environment (lookupEnv)
import qualified LawSpecRuntime as LS
import qualified LawSpecDefinitionBodies as Bodies
import qualified LawSpecDefinitions.Fixture as Native
reject name stage result = case result of
  Left message -> unless (all (\`isInfixOf\` message) [name ++ ":", stage] && not ("division by zero" \`isInfixOf\` message)) (fail message)
  Right _ -> fail ("accepted " ++ name)
check expected result = case result of
  Right actual | actual == expected -> pure ()
  _ -> fail ("unexpected result " ++ show result)
main = do
  symbols <- LS.newSymbolContext
  mutant <- lookupEnv "CONTRACT_MUTANT"
  if mutant == Just "1" then reject "next" "postcondition" (Native.next symbols 1) else do
    unless (LS.allElements (LS.SList []) (error "unreachable") == LS.SBool True) (fail "empty List")
    let visit value = if LS.truth value then error "unreachable" else LS.SBool False
    unless (LS.allElements (LS.SList [LS.SBool False, LS.SBool True]) visit == LS.SBool False) (fail "short circuit")
    check (3 % 2) (Native.sumreciprocal symbols [1, 2])
    check (0 % 1) (Native.sumreciprocal symbols [])
    check (1 % 1) (Native.sumrows symbols [[], [1, 2], [-2]])
    check [2] (Native.positivetail symbols [1, 2])
    check 1 (Native.positivefirst symbols [])
    reject "sumreciprocal" "precondition" (Native.sumreciprocal symbols [1, 0])
    reject "sumrows" "precondition" (Native.sumrows symbols [[0]])
    check [1, 2] (Native.keep symbols [1, 2])
    check [11] (Native.stronger symbols [11])
    check [1] (Native.reuse symbols [1])
    check [] (Native.empty symbols 0)
    check [1] (Native.singleton symbols 1)
    reject "keep" "precondition" (Native.keep symbols [1, 0])
    reject "stronger" "precondition" (Native.stronger symbols [1])
    reject "reuse" "precondition" (Native.reuse symbols [0])
    check True (Native.allpositive symbols [])
    check True (Native.allpositive symbols [1, 2])
    check False (Native.allpositive symbols [0, -1])
    check True (Native.nestedabove symbols [[], [3, 4]])
    check False (Native.nestedabove symbols [[1, 2]])
    check 128 (Native.next symbols 127)
    check 2 (Native.caller symbols 1)
    check 2 (Native.ordered symbols 2)
    check 127 (Native.narrow symbols 126)
    check (1 % 2) (Native.reciprocal symbols 2)
    reject "next" "precondition" (Native.next symbols 0)
    reject "caller" "precondition" (Native.caller symbols 0)
    reject "reciprocal" "precondition" (Native.reciprocal symbols 0)
    reject "ordered" "precondition" (Native.ordered symbols 0)
    reject "ordered" "precondition" (Native.ordered symbols (-1))
    reject "narrow" "precondition" (Native.narrow symbols 127)
    reject "next" "precondition" (Bodies.evaluate0 symbols (LS.SInteger "Int8" 0))
`;
for (const bits of [32, 64]) for (const mode of ['pretty', 'compact']) {
  const directory = path.join(base, String(bits), mode);
  await writeFile(path.join(directory, 'Main.hs'), source);
  const body = path.join(directory, 'LawSpecDefinitionBodies.hs');
  const original = await readFile(body, 'utf8');
  if (mode === 'pretty') assert.deepEqual(original.split('\n').filter(line => line.length > 80), []);
  const run = mutant => {
    execFileSync(ghc, ['--make', 'Main.hs', '-O0', '-outputdir', 'build', '-o', 'check'], {cwd: directory, stdio: 'inherit'});
    execFileSync(path.join(directory, 'check'), [], {cwd: directory,
      env: {...process.env, CONTRACT_MUTANT: mutant ? '1' : ''}, stdio: 'inherit'});
  };
  run(false);
  const start = original.indexOf('evaluate0 symbols');
  const end = original.indexOf('evaluate1 ::');
  assert.ok(start >= 0 && end > start);
  const method = original.slice(start, end);
  const changed = method.replace(/let result =[\s\S]*?\n(\s*)checkedResult <-/, 'let result = LS.SInteger "Integer" 0\n$1checkedResult <-');
  assert.notEqual(changed, method);
  try { await writeFile(body, original.slice(0, start) + changed + original.slice(end)); run(true); }
  finally { await writeFile(body, original); }
  console.log(`haskell ${bits} ${mode}: native contracts, direct logical checks and corrupted-result rejection passed`);
}
