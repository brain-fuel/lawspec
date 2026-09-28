// Generated callbacks, native APIs, native shrinking, and independent layout QA.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_PYTHON_CONSTRUCTOR_FIXTURE;
const python = process.env.LAWSPEC_PYTHON ?? 'python3.13';
const checker = process.env.LAWSPEC_PYCODESTYLE;
assert.ok(fixture && checker, 'Set LAWSPEC_PYTHON_CONSTRUCTOR_FIXTURE and LAWSPEC_PYCODESTYLE');
const base = path.join(root, '.artifacts/python-constructor-output');
execFileSync(fixture, [path.join(root, 'test/fixtures/python_constructor_fields.lawspec'), base]);
const audit = `
import ast
from pathlib import Path
import subprocess
import sys
base, checker = Path(sys.argv[1]), sys.argv[2]
count = 0
for bits in (32, 64):
    pretty, compact = base / str(bits) / 'pretty', base / str(bits) / 'compact'
    assert {p.relative_to(pretty) for p in pretty.rglob('*.py')} == {
        p.relative_to(compact) for p in compact.rglob('*.py')}
    subprocess.run([sys.executable, checker, '--max-line-length=79',
                    '--max-doc-length=72', str(pretty)], check=True)
    for source in pretty.rglob('*.py'):
        other = compact / source.relative_to(pretty)
        assert ast.dump(ast.parse(source.read_text())) == ast.dump(
            ast.parse(other.read_text())), str(source)
        count += 1
print(f'{count} generated artifacts pass PEP 8 and readable/compact AST parity')
`;
console.log(execFileSync(python, ['-c', audit, base, checker], {encoding: 'utf8'}).trim());
const mutate = `
import ast
import sys
from pathlib import Path
path = Path(sys.argv[1])
tree = ast.parse(path.read_text())
index = int(sys.argv[2])
name = '_lawspec_field_predicate' + str(index)
found = [node for node in ast.walk(tree)
         if isinstance(node, ast.FunctionDef) and node.name == name]
assert len(found) == 1
expression = 'True' if index == 0 else '_fields[0].description == "same"'
found[0].body = [ast.Return(ast.parse(expression, mode='eval').body)]
path.write_text(ast.unparse(ast.fix_missing_locations(tree)) + '\\n')
`;
for (const bits of [32, 64]) {
  for (const layout of ['pretty', 'compact']) {
    const directory = path.join(base, String(bits), layout);
    const env = {...process.env, PYTHONDONTWRITEBYTECODE: '1', PYTHONPATH: [
      path.join(directory, 'src'), path.join(directory, 'tests'),
      process.env.LAWSPEC_PYTHON_DEPS ?? path.join(root, '.artifacts/python-data-deps'),
    ].join(path.delimiter)};
    const run = () => spawnSync(python, [path.join(root,
      'test/runtime/PythonGeneratedConstructorCheck.py'), String(bits)], {
      env, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
    });
    const correct = run();
    await writeFile(path.join(directory, 'correct.log'), correct.stdout + correct.stderr);
    assert.equal(correct.status, 0, correct.stdout + correct.stderr);
    const source = path.join(directory, 'src/lawspec_data.py');
    const original = await readFile(source, 'utf8');
    for (const [index, name] of ['ignored-gap', 'symbol-description'].entries()) {
      try {
        execFileSync(python, ['-c', mutate, source, String(index)]);
        const mutant = run();
        await writeFile(path.join(directory, `${name}.log`), mutant.stdout + mutant.stderr);
        assert.notEqual(mutant.status, 0, name);
        assert.match(mutant.stdout + mutant.stderr, /invalid field value was accepted/);
      } finally {
        await writeFile(source, original);
      }
    }
    console.log(`Generated Python contracts: ${bits}/${layout}, native APIs, shrinking and two mutants passed`);
  }
}
