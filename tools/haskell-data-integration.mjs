import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_HASKELL_DATA_FIXTURE;
const ghc = process.env.LAWSPEC_GHC;
assert.ok(fixture && ghc, 'Set LAWSPEC_HASKELL_DATA_FIXTURE and LAWSPEC_GHC');
const directory = path.join(root, '.artifacts/haskell-native-data');
execFileSync(fixture, [directory]);
for (const mode of ['pretty', 'compact']) {
  const project = path.join(directory, mode);
  await writeFile(path.join(project, 'Main.hs'),
    (await readFile(path.join(root, 'test/runtime/HaskellDataCheck.hs'), 'utf8'))
      .replace('import Control.Exception', 'import HaskellConstructorCodecsCheck (checkConstructorCodecs)\nimport HaskellSchemaCheck (checkSchemas)\nimport HaskellCodecCheck (checkCodecs)\nimport HaskellStrategiesCheck (checkStrategies)\nimport Control.Exception')
      .replace('main = do', 'main = do\n  checkConstructorCodecs\n  checkSchemas\n  checkCodecs\n  checkStrategies'));
  await writeFile(path.join(project, 'HaskellConstructorCodecsCheck.hs'),
    await readFile(path.join(root, 'test/runtime/HaskellConstructorCodecsCheck.hs'), 'utf8'));
  await writeFile(path.join(project, 'HaskellSchemaCheck.hs'),
    await readFile(path.join(root, 'test/runtime/HaskellSchemaCheck.hs'), 'utf8'));
  await writeFile(path.join(project, 'HaskellCodecCheck.hs'),
    await readFile(path.join(root, 'test/runtime/HaskellCodecCheck.hs'), 'utf8'));
  for (const [file, source] of [['LawSpecDataStrategies.hs', 'runtime'],
    ['HaskellStrategiesCheck.hs', 'test/runtime']]) {
    await writeFile(path.join(project, file),
      await readFile(path.join(root, source, file), 'utf8'));
  }
  execFileSync(ghc, [...(process.env.LAWSPEC_GHC_PACKAGE_DB
    ? ['-package-db', process.env.LAWSPEC_GHC_PACKAGE_DB] : []), '--make', 'Main.hs', '-O0', '-i.', '-outputdir', 'build',
    '-o', 'check-native'], {cwd: project, stdio: 'inherit'});
  execFileSync(path.join(project, 'check-native'), [], {cwd: project, stdio: 'inherit'});
  const codecsPath = path.join(project, 'LawSpecCodecs.hs');
  const original = await readFile(codecsPath, 'utf8');
  for (const [before, after] of [
    ['S.validateWith scope schema typeRef bits value', 'S.validate schema typeRef bits value'],
    ['listCodecWith scope schema bits element = codecWith scope schema bits',
      'listCodecWith scope schema bits element = codecWith Nothing schema bits'],
  ]) {
    assert.ok(original.includes(before), before);
    try {
      await writeFile(codecsPath, original.replace(before, after));
      execFileSync(ghc, [...(process.env.LAWSPEC_GHC_PACKAGE_DB
        ? ['-package-db', process.env.LAWSPEC_GHC_PACKAGE_DB] : []),
      '--make', 'Main.hs', '-O0', '-i.', '-outputdir', 'build', '-o', 'check-native'],
      {cwd: project, stdio: 'pipe'});
      const failure = spawnSync(path.join(project, 'check-native'), [],
        {cwd: project, encoding: 'utf8'});
      assert.notEqual(failure.status, 0, 'dropped codec scope must fail');
      assert.match(failure.stdout + failure.stderr, /ctor::Leaf predicate 1/);
    } finally {
      await writeFile(codecsPath, original);
    }
  }
  for (const source of [
    'bad :: Data.Tree Bool\nbad = Data.TreeLeaf (1 :: Int8)',
    'bad :: Data.Empty Int8\nbad = ()',
    'bad = Data.StringsTexts "text" [] (LS.CodePointText []) (LS.Utf16Text [])',
  ]) {
    await writeFile(path.join(project, 'Invalid.hs'),
      `module Invalid where\nimport Data.Int\nimport qualified LawSpecData as Data\nimport qualified LawSpecRuntime as LS\n${source}\n`);
    const result = spawnSync(ghc, ['--make', 'Invalid.hs', '-fno-code', '-i.',
      '-outputdir', 'invalid-build'], {cwd: project, encoding: 'utf8'});
    assert.notEqual(result.status, 0, source);
    assert.match(result.stderr, /Couldn't match/);
  }
  console.log(`Haskell native data and rejected payload types passed: ${mode}`);
}
