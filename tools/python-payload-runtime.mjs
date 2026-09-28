import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdir, copyFile, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const directory = path.join(root, '.artifacts/python-payload-runtime');
const python = process.env.LAWSPEC_PYTHON ?? 'python3.13';
await mkdir(directory, {recursive: true});
for (const name of ['lawspec_runtime.py', 'lawspec_schema.py']) {
  await copyFile(path.join(root, 'runtime', name), path.join(directory, name));
}
if (process.env.LAWSPEC_CORE) {
  const content = await readFile(path.join(root, 'examples/specs/data_types.lawspec'), 'utf8');
  for (const machineBits of [32, 64]) {
    for (const minify of [false, true]) {
      const generated = spawnSync(process.env.LAWSPEC_CORE, [], {
        input: JSON.stringify({method: 'planGeneration', target: 'python',
          machineBits, minify, sources: [{path: 'data.lawspec', content}]}),
        encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
      });
      assert.equal(generated.status, 0, generated.stderr);
      const result = JSON.parse(generated.stdout);
      assert.deepEqual(result.diagnostics, []);
      const destination = path.join(directory, `${machineBits}-${minify}`);
      await mkdir(destination, {recursive: true});
      for (const name of ['lawspec_runtime.py', 'lawspec_schema.py']) {
        const artifact = result.files.find(file => file.path.endsWith('/' + name));
        assert.ok(artifact, name);
        await writeFile(path.join(destination, name), artifact.content);
      }
      const check = spawnSync(python, ['-B',
        path.join(root, 'test/runtime/PythonPayloadCheck.py')], {
        cwd: destination, env: {...process.env, PYTHONPATH: destination},
        encoding: 'utf8', timeout: 30000,
      });
      assert.equal(check.error, undefined);
      assert.equal(check.status, 0, check.stdout + check.stderr);
    }
  }
  console.log('Generated Python runtimes execute payload checks at both widths and layouts');
}
const file = path.join(directory, 'lawspec_schema.py');
const source = await readFile(file, 'utf8');
const run = () => spawnSync(python, ['-B',
  path.join(root, 'test/runtime/PythonPayloadCheck.py')], {
  cwd: directory, env: {...process.env, PYTHONPATH: directory},
  encoding: 'utf8', timeout: 30000,
});
const baseline = run();
assert.equal(baseline.error, undefined);
assert.equal(baseline.status, 0, baseline.stdout + baseline.stderr);
for (const [before, after] of [
  ['return arguments[field.index]', 'return arguments[0]'],
  ['else None)\n\n        def contextual', 'else Parameter(0))\n\n        def contextual'],
  ['checked = self.validate(reference, value, bits, symbols)\n\n        def recipe',
    'checked = value\n\n        def recipe'],
  ['                return result\n            name, arguments = plan.name',
    '                return True\n            name, arguments = plan.name'],
]) {
  assert.ok(source.includes(before), before);
  try {
    await writeFile(file, source.replace(before, after));
    const result = run();
    assert.equal(result.error, undefined);
    assert.notEqual(result.status, 0, `Payload mutant survived: ${before}`);
    assert.match(result.stderr, /FAILED \(/);
  } finally {
    await writeFile(file, source);
  }
}
console.log('Python payload runtime: nine checks pass; four mutants rejected');
