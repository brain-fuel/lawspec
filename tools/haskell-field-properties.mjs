import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const ghc = process.env.LAWSPEC_GHC;
assert.ok(compiler && ghc, 'Set LAWSPEC_CORE and LAWSPEC_GHC');
const packageArgs = process.env.LAWSPEC_GHC_PACKAGE_DB
  ? ['-package-db', process.env.LAWSPEC_GHC_PACKAGE_DB] : [];
const source = (await readFile(path.join(root, 'test/fixtures/constructor_properties.lawspec'), 'utf8')) + `
sameSymbol :: Symbol -> Symbol -> Bool
law \`disjunctive fixture inputs\` is definition is
  \`for all\` (x :: Identity)
    (s :: Symbol where s == symbol("fixture", "same") || s == symbol("other", "same")) .
    sameSymbol s symbol("fixture", "same") = (s == symbol("fixture", "same"))
end end
`;
for (const machineBits of [32, 64]) {
  for (const minify of [false, true]) {
    const directory = path.join(root, '.artifacts/haskell-field-properties', machineBits + '-' + minify);
    const sourceDir = machineBits === 32 ? 'library/native' : 'src';
    const testDir = machineBits === 32 ? 'checks/generated' : 'test';
    const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
      method: 'planGeneration', target: 'haskell', machineBits, minify, sourceDir, testDir,
      generation: {cases: 7, maxAttempts: 2, maxShrinks: 10},
      sources: [{path: 'fields.lawspec', content: source}],
    }), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024}));
    assert.deepEqual(result.diagnostics, []);
    let adapterPath, adapterSource, strategyPath, strategySource;
    for (const file of result.files) {
      assert.ok(file.path.startsWith((file.placement === 'test' ? testDir : sourceDir) + '/'));
      const destination = path.join(directory, file.path);
      await mkdir(path.dirname(destination), {recursive: true});
      let content = file.content;
      if (file.ownership === 'user') {
        content = content.replace(/echoAdapter _ = error "[^"]*"/, 'echoAdapter value = value')
          .replace(/sameSymbol _ _ = error "[^"]*"/, 'sameSymbol first second = first == second');
        assert.match(content, /echoAdapter value = value/);
        assert.match(content, /sameSymbol first second = first == second/);
        adapterPath = destination;
        adapterSource = content;
      }
      if (file.path.endsWith('/LawSpecDataStrategies.hs')) {
        strategyPath = destination;
        strategySource = content;
      }
      if (file.path.endsWith('/FieldsSpec.hs')) {
        assert.match(content, /Hedgehog.withTests\s*\(7\)/);
        assert.match(content, /Hedgehog.withDiscards\s*\(2\)/);
        assert.match(content, /Hedgehog.withShrinks\s*\(10\)/);
        assert.match(content, /law11Boundary0/);
        assert.doesNotMatch(content, /finite field domain property/);
      }
      await writeFile(destination, content);
    }
    await writeFile(path.join(directory, 'Main.hs'),
      'import Test.Hspec\nimport qualified Native.FieldsSpec as Fields\nmain = hspec Fields.spec\n');
    const args = [...packageArgs, '--make', 'Main.hs', `-i${sourceDir}`, `-i${testDir}`,
      '-O0', '-outputdir', 'build', '-o', 'check'];
    function build() {
      execFileSync(ghc, args, {cwd: directory, encoding: 'utf8', stdio: 'pipe'});
    }
    build();
    const output = execFileSync(path.join(directory, 'check'), [],
      {cwd: directory, encoding: 'utf8', timeout: 60000});
    await writeFile(path.join(directory, 'correct.log'), output);
    assert.equal((output.match(/passed 7 tests/g) ?? []).length, 13);
    for (const [destination, original, before, after, marker] of [
      [adapterPath, adapterSource, 'echoAdapter value = value',
        'echoAdapter _ = Data.IdentityIdentity (LS.Symbol "other" "same")', 'constructor field contract'],
      [adapterPath, adapterSource, 'first == second', 'True', 'disjunctive fixture inputs'],
      [strategyPath, strategySource, 'Right _ -> True',
        'Right _ -> False', 'gave up after'],
      [strategyPath, strategySource, 'Right _ -> True',
        'Right _ -> error "forced checked strategy error"', 'forced checked strategy error'],
    ]) {
      assert.ok(original.includes(before), before);
      try {
        await writeFile(destination, original.replace(before, after));
        build();
        const failure = spawnSync(path.join(directory, 'check'), [],
          {cwd: directory, encoding: 'utf8', timeout: 30000, maxBuffer: 64 * 1024 * 1024});
        await writeFile(path.join(directory, marker.replaceAll(' ', '-') + '.log'),
          failure.stdout + failure.stderr);
        assert.equal(failure.error, undefined);
        assert.notEqual(failure.status, 0, 'public constructor mutant must fail');
        assert.match(failure.stdout + failure.stderr, new RegExp(marker, 'i'));
        if (marker === 'gave up after') {
          assert.equal((failure.stdout.match(/gave up after 2 discards/g) ?? []).length, 13);
        }
      } finally {
        await writeFile(destination, original);
      }
    }
    console.log(`Haskell public constructor properties passed: ${machineBits}, minify=${minify}`);
  }
}
