import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {readFile, writeFile, readdir} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_GO_CONSTRUCTOR_FIXTURE;
assert.ok(fixture, 'Set LAWSPEC_GO_CONSTRUCTOR_FIXTURE');
const directory = path.join(root, '.artifacts/go-constructor-native');
execFileSync(fixture, [path.join(root, 'test/fixtures/python_constructor_fields.lawspec'), directory]);
const env = {...process.env, GOCACHE: path.join(root, '.artifacts/go-cache'),
  GOTOOLCHAIN: 'local', GOPROXY: 'off'};
for (const bits of [32, 64]) {
  for (const mode of ['pretty', 'compact']) {
    const project = path.join(directory, String(bits), mode);
    const sourceDir = path.join(project, 'native/fields');
    for (const name of await readdir(sourceDir)) {
      if (!name.endsWith('.go') || name.endsWith('_test.go')) continue;
      const source = await readFile(path.join(sourceDir, name), 'utf8');
      assert.doesNotMatch(source, /pgregory.net\/rapid/);
      if (mode === 'pretty') {
        const formatted = execFileSync('gofmt', [], {input: source, encoding: 'utf8'});
        assert.equal(source, formatted, name);
      }
    }
    await writeFile(path.join(sourceDir, 'native_test.go'),
      (await readFile(path.join(root, 'test/runtime/GoNativeConstructorCheck.go'), 'utf8')) +
      '\nconst profileBits = ' + bits + '\n');
    execFileSync('go', ['test', '-count=1', './...'], {cwd: project, env, stdio: 'inherit'});
    for (const [name, pattern, replacement] of [
      ['lawspec_schema.go', /if !predicate\(s, t.arguments, fields, bits, symbols\)/,
        'if false && !predicate(s, t.arguments, fields, bits, symbols)'],
      ['lawspec_definitions.go', /lawSpecIdentityCodec\(schema,\s*bits,\s*symbols\)/, 'lawSpecIdentityCodec(schema, bits)'],
    ]) {
      const destination = path.join(sourceDir, name);
      const original = await readFile(destination, 'utf8');
      assert.match(original, pattern);
      try {
        await writeFile(destination, original.replace(pattern, replacement));
        const result = spawnSync('go', ['test', '-count=1', './...'],
          {cwd: project, env, encoding: 'utf8'});
        assert.notEqual(result.status, 0, 'contract mutant must fail');
        assert.match(result.stdout + result.stderr, /--- FAIL: TestNativeConstructorContracts/,
          'mutant must compile and fail the test');
      } finally {
        await writeFile(destination, original);
      }
    }
    console.log('Go native constructor contracts passed: ' + bits + ', ' + mode);
  }
}
