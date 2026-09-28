// Compile generated native APIs, constructor predicates and Hedgehog properties.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_PAYLOAD_FIXTURE;
const ghc = process.env.LAWSPEC_GHC;
assert.ok(fixture && ghc, 'Set LAWSPEC_PAYLOAD_FIXTURE and LAWSPEC_GHC');
const packageArgs = process.env.LAWSPEC_GHC_PACKAGE_DB
  ? ['-package-db', process.env.LAWSPEC_GHC_PACKAGE_DB] : [];
const nativeCheck = `module NativeCheck (checkNative) where
import Control.Monad (unless)
import Data.List (isInfixOf)
import qualified LawSpecData as Data
import qualified LawSpecDefinitions.Payload as Payload
import qualified LawSpecRuntime as LS
checkNative = do
  symbols <- LS.newSymbolContext
  let value = Data.TreeNode [Data.TreeLeaf 2 (-128), Data.TreeLeaf 3 0]
      require label condition = unless condition (error label)
  require "captured threshold" (Payload.above symbols value 1 == Right True)
  require "rejected threshold" (Payload.above symbols value 2 == Right False)
  require "empty list" (Payload.positive symbols [] == Right True)
  require "rejected list" (Payload.positive symbols [1, 0] == Right False)
  require "valid constructor" (Payload.identity symbols (Data.PackPack value) ==
    Right (Data.PackPack value))
  require "generic constructor" (Payload.genericIdentity symbols
    (Data.GenericPackGenericPack value) == Right (Data.GenericPackGenericPack value))
  case Payload.identity symbols (Data.PackPack (Data.TreeLeaf 0 0)) of
    Left message -> require "constructor context"
      ("constructor field contract rejected" \`isInfixOf\` message)
    Right _ -> error "invalid constructor accepted"
  let symbol identity = LS.ScopedSymbol symbols identity "description"
  require "shared symbol" (Payload.shared symbols [symbol "shared"] == Right True)
  require "distinct symbol" (Payload.shared symbols [symbol "different"] == Right False)
`;
for (const bits of [32, 64]) for (const builtins of [false, true]) for (const compact of [false, true]) {
  const directory = path.join(root, `.artifacts/haskell-payload-emission/${bits}-${compact}-${builtins}`);
  execFileSync(fixture, [String(bits), compact ? 'True' : 'False', directory, 'haskell',
    ...(builtins ? ['builtins'] : [])]);
  const property = await readFile(path.join(directory, 'test/PayloadSpec.hs'), 'utf8');
  assert.match(property, /allPayloadsWith/);
  assert.match(property, /Hedgehog.check|hedgehog \$ do/);
  if (!compact && !builtins) for (const name of [
    'LawSpecDefinitionBodies.hs', 'LawSpecDefinitions/Payload.hs', 'LawSpecDataSchema.hs',
  ]) {
    const content = await readFile(path.join(directory, 'src', name), 'utf8');
    for (const line of content.split('\n')) assert.ok(line.length <= 80, `${name}: ${line}`);
  }
  await mkdir(directory, {recursive: true});
  if (!builtins) await writeFile(path.join(directory, 'NativeCheck.hs'), nativeCheck);
  await writeFile(path.join(directory, 'Main.hs'), 'import Test.Hspec\nimport qualified PayloadSpec\n' +
    (builtins ? '' : 'import NativeCheck\n') + 'main = do\n' +
    (builtins ? '' : '  checkNative\n') + '  hspec PayloadSpec.spec\n');
  const build = label => {
    const result = spawnSync(ghc, [...packageArgs, '--make', 'Main.hs', '-isrc', '-itest',
      '-outputdir', 'build', '-o', 'check'], {cwd: directory, encoding: 'utf8',
      maxBuffer: 16 * 1024 * 1024, timeout: 60000});
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    return writeFile(path.join(directory, label + '-build.log'), log).then(() => {
      assert.equal(result.error, undefined);
      assert.equal(result.status, 0, log);
    });
  };
  await build('correct');
  const run = args => spawnSync(path.join(directory, 'check'), args, {cwd: directory,
    encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, timeout: 60000});
  const result = run([]);
  const log = (result.stdout ?? '') + (result.stderr ?? '');
  await writeFile(path.join(directory, 'check.log'), log);
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, log);
  assert.match(log, /[1-9][0-9]* examples, 0 failures/);
  if (bits === 64 && builtins && !compact) {
    const file = path.join(directory, 'src/LawSpecSchema.hs');
    const original = await readFile(file, 'utf8');
    assert.ok(original.includes('LS.SBool <$> walk'));
    try {
      await writeFile(file, original.replace('LS.SBool <$> walk', 'const (LS.SBool True) <$> walk'));
      await build('mutant');
      const rejected = run(['--match', 'payload::all property']);
      const rejection = (rejected.stdout ?? '') + (rejected.stderr ?? '');
      await writeFile(path.join(directory, 'mutant.log'), rejection);
      assert.equal(rejected.error, undefined);
      assert.notEqual(rejected.status, 0, 'Hedgehog must reject accept-all traversal');
      assert.match(rejection, /1 example, 1 failure/);
    } finally {
      await writeFile(file, original);
    }
  }
}
console.log('Haskell payload native APIs, generic constructors, Symbols and Hedgehog properties pass eight configurations and an accept-all mutation; generated definition/schema lines fit 80 columns');
