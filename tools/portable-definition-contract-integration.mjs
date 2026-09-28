import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_PORTABLE_CONTRACT_FIXTURE;
const python = process.env.LAWSPEC_PYTHON ?? '/Users/mattlaine/.local/bin/python3.13';
const tsc = process.env.LAWSPEC_TSC ?? path.join(root, '.artifacts/web-data-deps/typescript/bin/tsc');
assert.ok(fixture, 'Set LAWSPEC_PORTABLE_CONTRACT_FIXTURE');
const base = path.join(root, `.artifacts/portable-definition-contracts${process.env.LAWSPEC_CONTRACT_SOURCE === '1' ? '-source' : ''}`);
execFileSync(fixture, [base]);
const pyCheck = `import sys
from fractions import Fraction
from lawspec_definitions import fixture as api
import lawspec_definition_bodies as bodies
import lawspec_runtime as runtime
symbols = {}
def reject(name, value, stage):
    try:
        getattr(api, name)(symbols, value)
    except ValueError as error:
        message = str(error)
        assert name + ':' in message and stage in message, message
        assert 'division by zero' not in message, message
    else:
        raise AssertionError('accepted ' + name)
if len(sys.argv) > 1:
    reject('next', 1, 'postcondition')
else:
    seen = []
    def visit(value):
        seen.append(value)
        if value == 2:
            raise ValueError('unreachable')
        return False
    assert runtime.all_elements([], visit) is True and seen == []
    assert runtime.all_elements([1, 2], visit) is False and seen == [1]
    assert api.sumreciprocal(symbols, [1, 2]) == Fraction(3, 2)
    assert api.sumreciprocal(symbols, []) == Fraction(0)
    assert api.sumrows(symbols, [[], [1, 2], [-2]]) == Fraction(1)
    assert api.positivetail(symbols, [1, 2]) == [2]
    assert api.positivefirst(symbols, []) == 1
    reject('sumreciprocal', [1, 0], 'precondition')
    reject('sumrows', [[0]], 'precondition')
    assert api.keep(symbols, [1, 2]) == [1, 2]
    assert api.stronger(symbols, [11]) == [11]
    assert api.reuse(symbols, [1]) == [1]
    assert api.empty(symbols, 0) == []
    assert api.singleton(symbols, 1) == [1]
    reject('keep', [1, 0], 'precondition')
    reject('stronger', [1], 'precondition')
    reject('reuse', [0], 'precondition')
    assert api.allpositive(symbols, []) is True
    assert api.allpositive(symbols, [1, 2]) is True
    assert api.allpositive(symbols, [0, -1]) is False
    assert api.nestedabove(symbols, [[], [3, 4]]) is True
    assert api.nestedabove(symbols, [[1, 2]]) is False
    assert api.next(symbols, 127) == 128
    assert api.caller(symbols, 1) == 2
    assert api.ordered(symbols, 2) == 2
    assert api.narrow(symbols, 126) == 127
    assert api.reciprocal(symbols, 2) == Fraction(1, 2)
    for name, value in [('next', 0), ('caller', 0), ('reciprocal', 0), ('ordered', 0), ('ordered', -1), ('narrow', 127)]:
        reject(name, value, 'precondition')
    try:
        bodies.evaluate_0(symbols, 0)
    except ValueError as error:
        assert 'precondition' in str(error)
    else:
        raise AssertionError('unchecked logical entry point')
`;
const webCheck = (prefix, ext) => `import assert from 'node:assert/strict';
import * as api from './${prefix}/lawspec_definitions/fixture.${ext}';
import * as bodies from './${prefix}/lawspec_definition_bodies.${ext}';
import * as runtime from './${prefix}/lawspec_runtime.${ext}';
const symbols = new Map();
function reject(name, value, stage) {
  assert.throws(() => api[name](symbols, value), error =>
    error.message.includes(name + ':') && error.message.includes(stage) && !error.message.includes('division by zero'));
}
if (process.argv.includes('mutant')) {
  reject('next', 1, 'postcondition');
} else {
  const seen = [];
  const visit = value => { seen.push(value); if (value === 2) throw new Error('unreachable'); return false; };
  assert.equal(runtime.allElements([], visit), true);
  assert.deepEqual(seen, []);
  assert.equal(runtime.allElements([1, 2], visit), false);
  assert.deepEqual(seen, [1]);
  const sum = api.sumreciprocal(symbols, [1, 2]);
  assert.equal(sum.n, 3n); assert.equal(sum.d, 2n);
  assert.equal(api.sumreciprocal(symbols, []).n, 0n);
  const rows = api.sumrows(symbols, [[], [1, 2], [-2]]);
  assert.equal(rows.n, 1n); assert.equal(rows.d, 1n);
  assert.deepEqual(api.positivetail(symbols, [1, 2]), [2]);
  assert.equal(api.positivefirst(symbols, []), 1);
  reject('sumreciprocal', [1, 0], 'precondition');
  reject('sumrows', [[0]], 'precondition');
  assert.deepEqual(api.keep(symbols, [1, 2]), [1, 2]);
  assert.deepEqual(api.stronger(symbols, [11]), [11]);
  assert.deepEqual(api.reuse(symbols, [1]), [1]);
  assert.deepEqual(api.empty(symbols, 0), []);
  assert.deepEqual(api.singleton(symbols, 1), [1]);
  reject('keep', [1, 0], 'precondition');
  reject('stronger', [1], 'precondition');
  reject('reuse', [0], 'precondition');
  assert.equal(api.allpositive(symbols, []), true);
  assert.equal(api.allpositive(symbols, [1, 2]), true);
  assert.equal(api.allpositive(symbols, [0, -1]), false);
  assert.equal(api.nestedabove(symbols, [[], [3, 4]]), true);
  assert.equal(api.nestedabove(symbols, [[1, 2]]), false);
  assert.equal(api.next(symbols, 127), 128n);
  assert.equal(api.caller(symbols, 1), 2n);
  assert.equal(api.ordered(symbols, 2), 2);
  assert.equal(api.narrow(symbols, 126), 127);
  const ratio = api.reciprocal(symbols, 2);
  assert.equal(ratio.n, 1n);
  assert.equal(ratio.d, 2n);
  for (const [name, value] of [['next', 0], ['caller', 0], ['reciprocal', 0], ['ordered', 0], ['ordered', -1], ['narrow', 127]]) reject(name, value, 'precondition');
  assert.throws(() => bodies.evaluate0(symbols, 0), /precondition/);
}
`;
for (const target of ['python', 'javascript', 'typescript']) for (const bits of [32, 64]) for (const mode of ['pretty', 'compact']) {
  const directory = path.join(base, target, String(bits), mode);
  const py = target === 'python';
  const ts = target === 'typescript';
  const extension = py ? 'py' : ts ? 'ts' : 'mjs';
  const body = path.join(directory, `src/lawspec_definition_bodies.${extension}`);
  const original = await readFile(body, 'utf8');
  const runner = path.join(directory, py ? 'check.py' : 'check.mjs');
  await writeFile(runner, py ? pyCheck : webCheck(ts ? 'dist' : 'src', ts ? 'js' : 'mjs'));
  await writeFile(path.join(directory, 'package.json'), '{"type":"module"}\n');
  if (ts) await writeFile(path.join(directory, 'tsconfig.json'), JSON.stringify({
    compilerOptions: {target: 'ES2022', module: 'NodeNext', moduleResolution: 'NodeNext', strict: true, outDir: 'dist', rootDir: 'src', skipLibCheck: true},
    include: ['src/**/*.ts'],
  }));
  function run(mutant) {
    if (ts) execFileSync(process.execPath, [tsc, '-p', directory], {stdio: 'inherit'});
    execFileSync(py ? python : process.execPath, [...(py ? ['-B'] : []), runner, ...(mutant ? ['mutant'] : [])], {
      cwd: directory, env: {...process.env, PYTHONPATH: path.join(directory, 'src')}, stdio: 'inherit',
    });
  }
  run(false);
  const mutation = py ? original.replace(/^        result =[\s\S]*?^        checked_result =/m, '        result = 0\n        checked_result =')
    : original.replace(/const result =[\s\S]*?;\s*const checked_result =/, 'const result = 0n;\nconst checked_result =');
  assert.notEqual(mutation, original, 'corrupted result must change the body');
  try { await writeFile(body, mutation); run(true); }
  finally { await writeFile(body, original); }
  console.log(`${target} ${bits} ${mode}: native contracts and corrupted-result rejection passed`);
}
