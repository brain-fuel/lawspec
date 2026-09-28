import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
assert.ok(compiler, 'Set LAWSPEC_CORE');
const source = (await readFile(path.join(root, 'test/fixtures/constructor_properties.lawspec'), 'utf8')) + `
sameSymbol :: Symbol -> Symbol -> Bool
law \`disjunctive fixture inputs\` is definition is
  \`for all\` (x :: Identity)
    (s :: Symbol where s == symbol("fixture", "same") || s == symbol("other", "same")) .
    sameSymbol s symbol("fixture", "same") = (s == symbol("fixture", "same"))
end end
`;
const rapid = path.join(execFileSync('go', ['env', 'GOMODCACHE'], {encoding: 'utf8'}).trim(),
  'pgregory.net/rapid@v1.2.0');
const env = {...process.env, GOCACHE: path.join(root, '.artifacts/go-cache'),
  GOTOOLCHAIN: 'local', GOPROXY: 'off'};
for (const machineBits of [32, 64]) {
  for (const minify of [false, true]) {
    const directory = path.join(root, '.artifacts/go-field-properties', machineBits + '-' + minify);
    const sourceDir = machineBits === 32 ? 'library/native' : undefined;
    const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
      method: 'planGeneration', target: 'go', machineBits, minify, sourceDir, testDir: sourceDir,
      generation: {cases: 7, maxAttempts: 2},
      sources: [{path: 'fields.lawspec', content: source}],
    }), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024}));
    assert.deepEqual(result.diagnostics, []);
    let adapterPath, adapterSource, strategyPath, strategySource;
    let adapterBoundaries = 0;
    for (const file of result.files) {
      const destination = path.join(directory, file.path);
      await mkdir(path.dirname(destination), {recursive: true});
      let content = file.content;
      if (file.path.endsWith('.go') && !minify) {
        assert.equal(execFileSync('gofmt', [], {input: content, encoding: 'utf8'}), content, file.path);
      }
      if (sourceDir) assert.ok(file.path.startsWith(sourceDir + '/'));
      if (file.path.endsWith('/adapter.go')) {
        assert.equal(file.ownership, 'user');
        content = content.replace('panic("echoAdapter")', 'lawSpecEchoCalls++; return value0')
          .replace('panic("sameSymbol")', 'return value0 == value1');
        content += '\nvar lawSpecEchoCalls int\n';
        adapterPath = destination;
        adapterSource = content;
      }
      if (file.path.endsWith('/lawspec_data_strategies_test.go')) {
        strategyPath = destination;
        strategySource = content;
      }
      if (file.path.endsWith('/lawspec_test.go')) {
        adapterBoundaries = [...content.matchAll(/func TestLaw0Boundary/g)].length;
        assert.match(content, /lsRapidCheck\(t,\s*7,/);
        assert.match(content, /TestLaw11Boundary0/);
        assert.doesNotMatch(content, /TestLaw11Property/);
      }
      await writeFile(destination, content);
    }
    await writeFile(path.join(directory, 'go.mod'),
      'module fixture\n\ngo 1.24.0\n\nrequire pgregory.net/rapid v1.2.0\nreplace pgregory.net/rapid => ' +
      JSON.stringify(rapid) + '\n');
    await writeFile(path.join(path.dirname(adapterPath), 'zz_case_count_test.go'),
      'package fields\nimport "testing"\nfunc TestRequestedCaseCount(t *testing.T) {\n' +
      'if lawSpecEchoCalls != ' + (7 + adapterBoundaries) +
      ' { t.Fatalf("got %d adapter calls", lawSpecEchoCalls) }\n}\n');
    const args = ['test', './...', '-count=1', '-run', '.', '-rapid.seed=424242',
      '-rapid.nofailfile'];
    execFileSync('go', args, {cwd: directory, env, stdio: 'inherit', timeout: 60000});
    for (const [destination, original, before, after] of [
      [adapterPath, adapterSource, 'return value0', 'return IdentityIdentity{Value: &LawSpecSymbol{description: "same"}}'],
      [adapterPath, adapterSource, 'return value0 == value1', 'return true'],
      [strategyPath, strategySource, 'result.value = schema.validate(reference, value, bits, symbols)',
        'panic("forced checked strategy error")'],
    ]) {
      assert.ok(original.includes(before), before);
      try {
        await writeFile(destination, original.replace(before, after));
        const failure = spawnSync('go', args, {cwd: directory, env, encoding: 'utf8', timeout: 30000});
        assert.equal(failure.error, undefined);
        assert.notEqual(failure.status, 0, 'public contract mutant must fail');
        assert.match(failure.stdout + failure.stderr, /--- FAIL: TestLaw/);
        if (destination === strategyPath) assert.match(failure.stdout + failure.stderr, /forced checked strategy error/);
      } finally {
        await writeFile(destination, original);
      }
    }
    console.log('Go public constructor contracts passed: ' + machineBits + ', minify=' + minify);
  }
}
