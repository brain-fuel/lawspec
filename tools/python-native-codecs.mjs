// Execute Python application codec hooks and native Hypothesis shrinking.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';

const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const python = process.env.LAWSPEC_PYTHON ?? 'python3.13';
assert.ok(compiler, 'Set LAWSPEC_CORE');
const wasm = await createCompiler();
const read = name => readFile(path.join(root, 'test/fixtures/native-codecs', name), 'utf8');
const content = await read('domain.lawspec');
const nativeBindings = JSON.parse(await read('bindings-python.json'));
const hooks = await read('codec_hooks.py');
for (const machineBits of [32, 64]) for (const minify of [false, true]) {
  const sourceDir = machineBits === 32 ? 'library/native' : 'src';
  const testDir = machineBits === 32 ? 'checks/native' : 'tests';
  const directory = path.join(root, `.artifacts/python-native-codec-hooks/${machineBits}-${minify}`);
  const request = {schemaVersion:4, method:'planGeneration', target:'python', machineBits,
    minify, sourceDir, testDir, nativeBindings, generation:{exhaustiveLimit:1},
    sources:[{path:'codecs.lawspec', content}]};
  const result = JSON.parse(execFileSync(compiler, [], {input:JSON.stringify(request), encoding:'utf8', maxBuffer:64*1024*1024}));
  assert.deepEqual(result.diagnostics, []);
  assert.deepEqual(await wasm.planGeneration(request), result, 'Python codec native/WASM parity');
  for (const file of result.files) {
    const destination = path.join(directory, file.path);
    await mkdir(path.dirname(destination), {recursive:true});
    await writeFile(destination, file.content);
  }
  for (const name of ['codec_domain.py', 'codec_hooks.py']) await writeFile(path.join(directory, sourceDir, name), await read(name));
  const generatorPath = path.join(directory, testDir, 'codec_generators.py');
  await writeFile(generatorPath, await read('codec_generators.py'));
  await writeFile(path.join(directory, 'check_source.py'), await readFile(path.join(root, 'test/runtime/PythonCodecBindingsCheck.py')));
  await writeFile(path.join(directory, testDir, 'test_codec_shrinking.py'), await readFile(path.join(root, 'test/runtime/PythonBoundCodecGeneratorCheck.py')));
  const env = {...process.env, PYTHONDONTWRITEBYTECODE:'1', PYTHONPATH:[path.join(directory,sourceDir), path.join(directory,testDir),
    process.env.LAWSPEC_PYTHON_DEPS ?? path.join(root,'.artifacts/python-data-deps')].join(path.delimiter)};
  const options = {cwd:directory, env, encoding:'utf8', maxBuffer:32*1024*1024};
  const source = spawnSync(python, ['-B', '-S', 'check_source.py'], {...options, env:{...env, PYTHONPATH:path.join(directory,sourceDir)}});
  await writeFile(path.join(directory, 'source-only.log'), source.stdout+source.stderr);
  assert.equal(source.status, 0, source.stdout+source.stderr);
  async function run(label) {
    const execution = spawnSync(python, ['-B', '-m', 'pytest', '-q', '--tb=short', '-x', testDir], options);
    const log = execution.stdout+execution.stderr;
    await writeFile(path.join(directory, `${label}.log`), log);
    return {...execution, log};
  }
  const correct = await run('correct');
  assert.equal(correct.status, 0, correct.log);
  const hookPath = path.join(directory, sourceDir, 'codec_hooks.py');
  for (const [label,before,after,expected] of [
    ['decoding-error','return domain.Positive(value.value)','raise ValueError("custom decoding failed")',/Positive toNative: custom decoding failed/],
    ['encoding-error','return data.PositivePositive(value.unpack())','raise ValueError("custom encoding failed")',/Positive fromNative: custom encoding failed/],
    ['invalid-result','data.PositivePositive(value.unpack())','data.PositivePositive(0)',/field refinement 1 failed/],
    ['collapsed-tail','Just(data.ChainStop()) if ended else Nothing()','Just(data.ChainStop())',/flattened recursive representation/],
  ]) {
    assert.ok(hooks.includes(before));
    await writeFile(hookPath, hooks.replace(before,after));
    const failed = await run(label);
    assert.equal(failed.status, 1, failed.log);
    assert.match(failed.log, expected);
    assert.doesNotMatch(failed.log, /ERROR collecting/);
  }
  await writeFile(hookPath, hooks);
  const generators = await read('codec_generators.py');
  await writeFile(generatorPath, generators.replace('st.integers(1, 100)', 'st.just(0)'));
  const invalid = await run('invalid-generator');
  assert.equal(invalid.status, 1, invalid.log);
  assert.match(invalid.log, /native generator .*Positive.*field refinement 1 failed/);
  await writeFile(generatorPath, generators);
  console.log(`Python codec hooks: private products, flat recursion, nested generics, shrinking and rejected mutants; ${machineBits}, compact=${minify}`);
}
