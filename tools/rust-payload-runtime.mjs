import assert from 'node:assert/strict';
import {spawnSync, execFileSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const directory = path.join(root, '.artifacts/rust-payload-runtime');
await mkdir(path.join(directory, 'src'), {recursive: true});
await writeFile(path.join(directory, 'Cargo.toml'),
  (await readFile(path.join(root, 'runtime/rust/Cargo.toml'), 'utf8'))
    .replace('lawspec-runtime-conformance', 'lawspec-payload-check')
    .replace('../lawspec_runtime.rs', 'src/lib.rs'));
await writeFile(path.join(directory, 'src/lib.rs'),
  await readFile(path.join(root, 'test/runtime/RustPayloadCheck.rs')));
const file = path.join(directory, 'src/lawspec_runtime.rs');
const source = await readFile(path.join(root, 'runtime/lawspec_runtime.rs'), 'utf8');
await writeFile(file, source);
const run = (filter = []) => spawnSync('cargo', ['test', '--offline', '--quiet', ...filter], {
  cwd: directory, encoding: 'utf8', timeout: 60000, maxBuffer: 4 * 1024 * 1024,
});
const baseline = run();
assert.equal(baseline.error, undefined);
assert.equal(baseline.status, 0, baseline.stdout + baseline.stderr);
for (const [before, after] of [
  ['TypeRef::Parameter(index) => arguments\n                .get(*index)',
    'TypeRef::Parameter(_index) => arguments\n                .get(0)'],
  ['                        Self::Ignore\n                    } else {',
    '                        Self::Parameter(0)\n                    } else {'],
  ['let checked = self.validate_with_context(value, ty, bits, context)?;\n        let plan',
    'let checked = value;\n        let plan'],
  ['return predicate(*index, value, context)?.boolean()',
    'return predicate(*index, value, context).map(|_| true)'],
]) {
  assert.ok(source.includes(before), before);
  try {
    await writeFile(file, source.replace(before, after));
    const result = run(['payload_']);
    assert.equal(result.error, undefined);
    assert.notEqual(result.status, 0, `Payload mutant survived: ${before}`);
    assert.match(result.stdout, /test result: FAILED/);
  } finally {
    await writeFile(file, source);
  }
}
console.log('Rust payload checks and 22 existing runtime tests pass; four compiled mutants rejected');
if (process.env.LAWSPEC_CORE) {
  const content = await readFile(path.join(root, 'examples/specs/data_types.lawspec'), 'utf8');
  for (const machineBits of [32, 64]) for (const minify of [false, true]) {
    const result = JSON.parse(execFileSync(process.env.LAWSPEC_CORE, [], {
      input: JSON.stringify({method: 'planGeneration', target: 'rust', machineBits, minify,
        sources: [{path: 'data.lawspec', content}]}), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
    }));
    assert.deepEqual(result.diagnostics, []);
    const artifact = result.files.find(file => file.path.endsWith('/lawspec_runtime.rs'));
    assert.ok(artifact);
    try {
      await writeFile(file, artifact.content);
      const result = run();
      assert.equal(result.error, undefined);
      assert.equal(result.status, 0, result.stdout + result.stderr);
    } finally {
      await writeFile(file, source);
    }
  }
  console.log('Generated Rust payload runtimes compile and execute at both widths/layouts');
}
