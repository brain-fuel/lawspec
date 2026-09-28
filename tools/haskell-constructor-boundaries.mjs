import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const ghc = process.env.LAWSPEC_GHC;
const fixture = process.env.LAWSPEC_HASKELL_BOUNDARIES_FIXTURE;
const definitions = process.env.LAWSPEC_HASKELL_DEFINITIONS_FIXTURE;
assert.ok(ghc && fixture && definitions, 'Set GHC and both Haskell fixture paths');
const packageArgs = process.env.LAWSPEC_GHC_PACKAGE_DB
  ? ['-package-db', process.env.LAWSPEC_GHC_PACKAGE_DB] : [];
const directory = path.join(root, '.artifacts/haskell-constructor-boundaries');
await mkdir(directory, {recursive: true});
const source = path.join(directory, 'fields.lawspec');
await writeFile(source, await readFile(path.join(root, 'test/fixtures/constructor_properties.lawspec')));
for (const bits of [32, 64]) {
  const output = path.join(directory, String(bits));
  execFileSync(definitions, [String(bits), output, source]);
  execFileSync(fixture, [String(bits), output, source]);
  for (const mode of ['pretty', 'compact']) {
    const project = path.join(output, mode);
    await writeFile(path.join(project, 'LawSpecDataStrategies.hs'),
      await readFile(path.join(root, 'runtime/LawSpecDataStrategies.hs')));
    const adapter = path.join(project, 'src/Native/Fields.hs');
    const stub = await readFile(adapter, 'utf8');
    assert.match(stub, /echoAdapter _ = error/);
    await writeFile(adapter, stub.replace(/echoAdapter _ = error "[^"]*"/, 'echoAdapter value = value'));
    await writeFile(path.join(project, 'Main.hs'),
      'import Test.Hspec\nimport qualified Native.FieldsSpec as Fields\nmain = hspec Fields.spec\n');
    const args = [...packageArgs, '--make', 'Main.hs', '-i.', '-isrc', '-itest',
      '-O0', '-outputdir', 'build', '-o', 'check'];
    execFileSync(ghc, args, {cwd: project, stdio: 'pipe'});
    execFileSync(path.join(project, 'check'), [], {cwd: project, stdio: 'inherit'});
    const specPath = path.join(project, 'test/Native/FieldsSpec.hs');
    const spec = await readFile(specPath, 'utf8');
    for (const [before, after] of [
      ['Schema.constructWith (P.Just (symbols))', 'Schema.constructWith P.Nothing'],
      ['Schema.validateWith (P.Just (symbols))', 'Schema.validateWith P.Nothing'],
      ['Codecs.identityCodecWith (P.Just (symbols))', 'Codecs.identityCodecWith P.Nothing'],
    ]) {
      // Compact rendering makes call syntax deterministic for mutation.
      if (mode !== 'compact') continue;
      assert.ok(spec.includes(before), before);
      try {
        await writeFile(specPath, spec.replaceAll(before, after));
        execFileSync(ghc, args, {cwd: project, stdio: 'pipe'});
        const failure = spawnSync(path.join(project, 'check'), [], {cwd: project, encoding: 'utf8'});
        assert.equal(failure.error, undefined);
        assert.notEqual(failure.status, 0, 'lost Symbol context must fail execution');
      } finally {
        await writeFile(specPath, spec);
      }
    }
    console.log(`Haskell constructor boundaries passed: ${bits}, ${mode}`);
  }
}
