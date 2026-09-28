import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const directory = path.join(root, '.artifacts/go-constructor-contracts');
await mkdir(directory, {recursive: true});
const env = {...process.env, GOCACHE: path.join(root, '.artifacts/go-cache'),
  GOTOOLCHAIN: 'local', GOPROXY: 'off'};
await writeFile(path.join(directory, 'go.mod'), 'module fixture\n\ngo 1.24.0\n');
for (const name of ['lawspec_runtime.go', 'lawspec_schema.go']) {
  const source = (await readFile(path.join(root, 'runtime', name), 'utf8'))
    .replace('package RUNTIME_PACKAGE', 'package fixture');
  assert.equal(execFileSync('gofmt', [], {input: source, encoding: 'utf8'}), source);
  await writeFile(path.join(directory, name), source);
}
await writeFile(path.join(directory, 'contracts_test.go'),
  await readFile(path.join(root, 'test/runtime/GoConstructorContractsCheck.go'), 'utf8'));
execFileSync('go', ['test', '-v', './...'], {cwd: directory, env, stdio: 'inherit'});
const schemaPath = path.join(directory, 'lawspec_schema.go');
const source = await readFile(schemaPath, 'utf8');
for (const [before, after] of [
  ['if !predicate(s, t.arguments, fields, bits, symbols)', 'if false && !predicate(s, t.arguments, fields, bits, symbols)'],
  ['predicates := append([]lawSpecFieldPredicate{}, contract.predicates...)', 'predicates := contract.predicates'],
  ['child, bits, path, symbols)', 'child, bits, path, map[string]*lawSpecSymbol{})'],
  ['accepted = false', 'accepted = true'],
  ['panic(problem)', 'accepted = false'],
]) {
  assert.ok(source.includes(before), before);
  try {
    await writeFile(schemaPath, source.replace(before, after));
    const result = spawnSync('go', ['test', './...'], {cwd: directory, env, encoding: 'utf8'});
    assert.notEqual(result.status, 0, 'mutant must fail');
    assert.match(result.stdout + result.stderr, /FAIL/, 'mutant must compile and fail tests');
  } finally {
    await writeFile(schemaPath, source);
  }
}
console.log('Go constructor contracts: both machine widths and five mutants passed');
