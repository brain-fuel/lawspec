import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {readFile, writeFile, unlink} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_GO_DATA_FIXTURE;
assert.ok(fixture, 'Set LAWSPEC_GO_DATA_FIXTURE');
const directory = path.join(root, '.artifacts/go-native-data');
execFileSync(fixture, [directory]);
const env = {...process.env, GOCACHE: path.join(root, '.artifacts/go-cache'),
  GOTOOLCHAIN: 'local', GOPROXY: 'off'};
for (const mode of ['pretty', 'compact']) {
  const project = path.join(directory, mode);
  const rapid = process.env.LAWSPEC_RAPID ?? path.join(
    execFileSync('go', ['env', 'GOMODCACHE'], {encoding: 'utf8'}).trim(),
    'pgregory.net/rapid@v1.2.0');
  await writeFile(path.join(project, 'go.mod'),
    'module fixture\n\ngo 1.24.0\n\nrequire pgregory.net/rapid v1.2.0\n' +
    `replace pgregory.net/rapid => ${JSON.stringify(rapid)}\n`);
  if (mode === 'pretty') {
    for (const name of ['lawspec_data.go', 'lawspec_data_schema.go', 'lawspec_schema.go', 'lawspec_codecs.go', 'lawspec_data_codecs.go', 'lawspec_data_strategies_test.go']) {
      const source = await readFile(path.join(project, name), 'utf8');
      const formatted = execFileSync('gofmt', [], {input: source, encoding: 'utf8'});
      assert.equal(source, formatted, `${name} matches gofmt`);
    }
  }
  await writeFile(path.join(project, 'data_test.go'),
    await readFile(path.join(root, 'test/runtime/GoDataCheck.go'), 'utf8'));
  await writeFile(path.join(project, 'schema_test.go'),
    await readFile(path.join(root, 'test/runtime/GoSchemaCheck.go'), 'utf8'));
  await writeFile(path.join(project, 'codecs_test.go'),
    await readFile(path.join(root, 'test/runtime/GoCodecCheck.go'), 'utf8'));
  await writeFile(path.join(project, 'strategies_test.go'),
    await readFile(path.join(root, 'test/runtime/GoStrategiesCheck.go'), 'utf8'));
  await writeFile(path.join(project, 'constructor_codecs_test.go'),
    await readFile(path.join(root, 'test/runtime/GoConstructorCodecsCheck.go'), 'utf8'));
  execFileSync('go', ['test', './...', '-rapid.seed=424242', '-rapid.nofailfile'], {cwd: project, env, stdio: 'inherit'});
  for (const [file, expression, replacement] of [
    ['lawspec_codecs.go', /schema\.validate\(typeRef,\s*value,\s*bits,\s*symbols\)/,
      'schema.validate(typeRef, value, bits)'],
    ['lawspec_codecs.go', /schema\.validate\(typeRef,\s*fromNative\(value,\s*path\),\s*bits,\s*symbols\)/,
      'schema.validate(typeRef, fromNative(value, path), bits)'],
    ['lawspec_data_codecs.go', /lsSchemaSymbols\(contexts\)/, 'lsSchemaSymbols(nil)'],
  ]) {
    const destination = path.join(project, file);
    const original = await readFile(destination, 'utf8');
    assert.match(original, expression, 'context mutant must change the generated source');
    try {
      await writeFile(destination, original.replace(expression, replacement));
      const result = spawnSync('go', ['test', '-run', '^TestConstructorCodecContexts$', './...'],
        {cwd: project, env, encoding: 'utf8'});
      assert.notEqual(result.status, 0, 'dropped codec context must fail');
      assert.match(result.stdout + result.stderr, /--- FAIL: TestConstructorCodecContexts/,
        'context mutant must compile and fail the runtime test');
    } finally {
      await writeFile(destination, original);
    }
  }
  for (const [name, minimal] of [
    ['TestDataShrinkLength', 'minimal_length=5'],
    ['TestDataShrinkTree', 'minimal_tree=Tree Int8(ctor::Leaf([Int8(1)]))'],
  ]) {
    const result = spawnSync('go', ['test', '-run', `^${name}$`,
      '-rapid.seed=424242', '-rapid.nofailfile'], {cwd: project,
      env: {...env, LAWSPEC_EXPECT_SHRINK: '1'}, encoding: 'utf8'});
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(project, `${name}.log`), log);
    assert.notEqual(result.status, 0, 'expected shrink failure');
    const failure = log.split('\n').find(line => line.includes('[rapid] failed after'));
    assert.ok(failure?.endsWith(minimal), log);
    assert.doesNotMatch(log, /panic|invalid shrink/);
  }
  for (const expression of [
    'var _ Tree[bool] = TreeLeaf[int8]{}',
    'var _ Phantom[bool] = PhantomTag[int8]{}',
    'var _ Tree[int8] = PairPair[int8]{}',
    'var _ Empty[int8] = struct{}{}',
    'var _ = PairPair[string]{Second: -1}',
  ]) {
    const invalid = path.join(project, 'invalid_test.go');
    await writeFile(invalid, `package fixture\n${expression}\n`);
    const result = spawnSync('go', ['test', './...'], {
      cwd: project, env, encoding: 'utf8',
    });
    await unlink(invalid);
    assert.notEqual(result.status, 0, expression);
    assert.match(result.stderr, /cannot use|overflows uint64/);
  }
  console.log(`Go native data, schemas, codecs, generation and shrinking passed: ${mode}`);
}
