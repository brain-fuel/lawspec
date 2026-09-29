import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const directory = path.join(root, '.artifacts/go-checked-strategies');
await mkdir(directory, {recursive: true});
const env = {...process.env, GOCACHE: path.join(root, '.artifacts/go-cache'),
  GOTOOLCHAIN: 'local', GOPROXY: 'off'};
const rapid = path.join(execFileSync('go', ['env', 'GOMODCACHE'], {encoding: 'utf8'}).trim(),
  'pgregory.net/rapid@v1.2.0');
await writeFile(path.join(directory, 'go.mod'),
  'module fixture\n\ngo 1.24.0\n\nrequire pgregory.net/rapid v1.2.0\nreplace pgregory.net/rapid => ' +
  JSON.stringify(rapid) + '\n');
for (const name of ['lawspec_runtime.go', 'lawspec_schema.go', 'lawspec_codecs.go', 'lawspec_data_strategies.go']) {
  const source = (await readFile(path.join(root, 'runtime', name), 'utf8'))
    .replace('package RUNTIME_PACKAGE', 'package fixture');
  assert.equal(execFileSync('gofmt', [], {input: source, encoding: 'utf8'}), source);
  await writeFile(path.join(directory, name), source);
}
await writeFile(path.join(directory, 'checked_test.go'),
  await readFile(path.join(root, 'test/runtime/GoCheckedStrategiesCheck.go'), 'utf8'));
const args = ['test', '-count=1', '-rapid.seed=424242', '-rapid.nofailfile', './...'];
execFileSync('go', args, {cwd: directory, env, stdio: 'inherit', timeout: 60000});
for (const [name, variable, expected] of [
  ['TestCheckedShrink', 'LAWSPEC_EXPECT_SHRINK', /minimal_values=\[1 1 1\]/],
  ['TestCheckedEmpty', 'LAWSPEC_EXPECT_EMPTY', /only generated 0 valid tests/],
]) {
  const result = spawnSync('go', ['test', '-count=1', '-run', '^' + name + '$',
    '-rapid.seed=424242', '-rapid.nofailfile', './...'],
  {cwd: directory, env: {...env, [variable]: '1'}, encoding: 'utf8', timeout: 30000});
  const log = result.stdout + result.stderr;
  await writeFile(path.join(directory, name + '.log'), log);
  assert.equal(result.error, undefined, 'native rejection must terminate');
  assert.notEqual(result.status, 0, 'deliberately failing property');
  assert.match(log, expected);
}
const strategyPath = path.join(directory, 'lawspec_data_strategies.go');
const original = await readFile(strategyPath, 'utf8');
for (const [before, after] of [
  ['setting.Value.Set(strconv.Itoa(cases))', 'setting.Value.Set(strconv.Itoa(cases + 1))'],
  ['if attempts >= 5', 'if attempts >= 1'],
  ['return !candidate.rejected', 'return candidate.rejected || !candidate.rejected'],
  ['result.problem = problem', 'result.rejected = true'],
  ['c.addWitness(schema, reference.arguments[0], child)', '_ = child'],
]) {
  assert.ok(original.includes(before), before);
  try {
    await writeFile(strategyPath, original.replace(before, after));
    const result = spawnSync('go', args, {cwd: directory, env, encoding: 'utf8', timeout: 30000});
    assert.equal(result.error, undefined);
    assert.notEqual(result.status, 0, 'strategy mutant must fail');
    assert.match(result.stdout + result.stderr, /--- FAIL: Test(CheckedStrategies|RapidSettings)/,
      'mutant must compile and fail the test');
  } finally {
    await writeFile(strategyPath, original);
  }
}
console.log('Go checked strategies: both widths, nested seeds, error propagation, shrinking and empty domains and five mutants passed');
