import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFile, readdir} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_PYTHON_PAYLOAD_FIXTURE;
const checker = process.env.LAWSPEC_PYCODESTYLE;
const python = process.env.LAWSPEC_PYTHON ?? 'python3.13';
assert.ok(fixture && checker, 'Set LAWSPEC_PYTHON_PAYLOAD_FIXTURE and LAWSPEC_PYCODESTYLE');
const check = `
import lawspec_data as data
from lawspec_definitions import payload
import test_payload_lawspec as properties
value = data.TreeNode([data.TreeLeaf(2, -128), data.TreeLeaf(3, 0)])
assert payload.above({}, value, 1) is True
assert payload.above({}, value, 2) is False
assert payload.positive({}, []) is True
assert payload.positive({}, [1, 2]) is True
assert payload.positive({}, [1, 0]) is False
assert isinstance(payload.identity({}, data.PackPack(value)), data.PackPack)
try:
    payload.identity({}, data.PackPack(data.TreeLeaf(0, 0)))
except ValueError as error:
    assert 'field refinement' in str(error), str(error)
else:
    raise AssertionError('invalid constructor payload accepted')
tests = [value for name, value in vars(properties).items() if name.startswith('test_')]
assert tests, 'generated property missing'
for test in tests:
    test()
`;
const audit = `
import ast
import importlib.util
import json
import sys
spec = importlib.util.spec_from_file_location('pycodestyle', sys.argv[1])
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)
style = checker.StyleGuide(config_file=False, max_line_length=79, max_doc_length=72)
for readable, compact in json.load(sys.stdin):
    assert ast.dump(ast.parse(readable)) == ast.dump(ast.parse(compact))
    assert checker.Checker(lines=readable.splitlines(True), options=style.options).check_all() == 0
`;
async function sources(directory) {
  const result = new Map();
  async function walk(dir) {
    for (const entry of await readdir(dir, {withFileTypes: true})) {
      const file = path.join(dir, entry.name);
      if (entry.isDirectory() && entry.name !== '__pycache__' && entry.name !== 'builtins') await walk(file);
      else if (entry.isFile() && entry.name.endsWith('.py')) {
        result.set(path.relative(directory, file), await readFile(file, 'utf8'));
      }
    }
  }
  await walk(directory);
  return result;
}
for (const bits of [32, 64]) {
  const modes = [];
  const builtinModes = [];
  for (const compact of [false, true]) {
    const directory = path.join(root, `.artifacts/python-payload-emission/${bits}-${compact}`);
    execFileSync(fixture, [String(bits), compact ? 'True' : 'False', directory]);
    execFileSync(python, ['-B', '-c', check], {cwd: directory,
      env: {...process.env, PYTHONPATH: [path.join(directory, 'src'),
        path.join(directory, 'tests'), path.join(root, '.artifacts/python-data-deps')].join(path.delimiter)},
      stdio: 'pipe', timeout: 60000});
    modes.push(await sources(directory));
    const builtinDirectory = path.join(directory, 'builtins');
    execFileSync(fixture, [String(bits), compact ? 'True' : 'False', builtinDirectory, 'builtins']);
    execFileSync(python, ['-B', '-c', `
import test_payload_lawspec as properties
tests = [value for name, value in vars(properties).items() if name.startswith('test_')]
assert tests
for test in tests:
    test()
`], {cwd: builtinDirectory, env: {...process.env, PYTHONPATH: [
      path.join(builtinDirectory, 'src'), path.join(builtinDirectory, 'tests'),
      path.join(root, '.artifacts/python-data-deps')].join(path.delimiter)},
      stdio: 'pipe', timeout: 60000});
    builtinModes.push(await sources(builtinDirectory));
  }
  assert.deepEqual([...modes[0].keys()].sort(), [...modes[1].keys()].sort());
  execFileSync(python, ['-c', audit, checker], {
    input: JSON.stringify([modes, builtinModes].flatMap(pair =>
      [...pair[0]].map(([name, content]) => [content, pair[1].get(name)]))),
    stdio: ['pipe', 'inherit', 'inherit'],
  });
}
console.log('Python payload definitions, constructor contracts and properties pass at both widths/layouts; PEP 8 and AST parity pass');
