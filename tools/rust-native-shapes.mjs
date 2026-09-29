import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {templates} from '../npm/templates.mjs';
import {createCompiler} from '../npm/api.mjs';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
assert.ok(compiler, 'Set LAWSPEC_CORE');
const wasm = await createCompiler();
const source = await readFile(path.join(root, 'test/fixtures/native_shapes.lawspec'), 'utf8');
const bindings = JSON.parse(await readFile(path.join(root, 'test/fixtures/native-shapes/bindings.json')));
if (process.env.LAWSPEC_NATIVE_GENERATORS === '1') bindings.generators = [
  {type:'native.shapes::type::Box',factory:['lawspec_generators','wrapped']},
  {type:'Int8',factory:['lawspec_generators','bytes']},
  {type:'native.shapes::type::Stamp',factory:['lawspec_generators','seals']},
];
for (const minify of [false, true]) {
  const request = {schemaVersion:4, method:'planGeneration', target:'rust', minify, generation:{exhaustiveLimit:1},
    sources:[{path:'native_shapes.lawspec',content:source}], nativeBindings:bindings};
  const result = JSON.parse(execFileSync(compiler, [], {encoding:'utf8', maxBuffer:32*1024*1024,
    input:JSON.stringify(request)}));
  assert.deepEqual(result.diagnostics, []);
  assert.deepEqual(await wasm.planGeneration(request), result, 'Native/WASM generic binding parity');
  const output = path.join(root, '.artifacts/rust-native-shapes', minify ? 'compact' : 'readable');
  for (const file of [...Object.entries(templates('rust')).map(([path,content]) => ({path,content})), ...result.files]) {
    const destination = path.join(output,file.path);
    await mkdir(path.dirname(destination),{recursive:true});
    await writeFile(destination,file.content);
  }
  await writeFile(path.join(output,'src/lib.rs'),'include!("lawspec_modules.rs");\npub mod domain;\n');
  await writeFile(path.join(output,'src/domain.rs'),await readFile(path.join(root,'test/fixtures/native-shapes/domain.rs')));
  await writeFile(path.join(output, 'tests/native_generators.rs'),
    '#![allow(dead_code)]\nuse lawspec_example::lawspec_runtime;\n#[path = "support/lawspec_strategies.rs"]\nmod ls_gen;\n' +
    await readFile(path.join(root, 'test/runtime/RustNativeGeneratorsCheck.rs'), 'utf8'));
  if (bindings.generators) {
    await writeFile(path.join(output, 'tests/support/lawspec_generators.rs'),
      await readFile(path.join(root, 'test/fixtures/native-shapes/generators.rs')));
    const checks = await readFile(path.join(root, 'test/runtime/RustBoundGenericGeneratorCheck.rs'), 'utf8');
    const tests = result.files.filter(file => file.path.endsWith('_lawspec.rs'));
    for (const file of tests) await writeFile(path.join(output, file.path), file.content + '\n' + checks);
  }
  execFileSync('cargo',['test','--offline','--quiet'],{cwd:output,stdio:'inherit',
    env:{...process.env,CARGO_TARGET_DIR:path.join(root,'.artifacts/rust-native-shapes/target')}});
  console.log(`Rust ${minify ? 'compact' : 'readable'}: generic, recursive, nested and empty native representations pass`);
}

// A generator is itself a native machine-sized boundary, even without adapters.
const nativeBits = Number(execFileSync('rustc', ['--print','cfg'], {encoding:'utf8'})
  .match(/target_pointer_width="(32|64)"/)[1]);
for (const machineBits of [32, 64]) {
  const output = path.join(root, '.artifacts/rust-native-shapes', `machine-${machineBits}`);
  const request = {schemaVersion:4, method:'planGeneration', target:'rust', machineBits,
    sources:[{path:'machine.lawspec',content:'unit native.machine\nlaw `identity` is definition is `for all` (x :: IntSize) . x = x end end'}],
    nativeBindings:{rustCrate:'lawspec_example',generators:[{type:'IntSize',factory:['lawspec_generators','sizes']}]}};
  const result = JSON.parse(execFileSync(compiler, [], {input:JSON.stringify(request),encoding:'utf8',maxBuffer:32*1024*1024}));
  assert.deepEqual(result.diagnostics,[]);
  assert.deepEqual(await wasm.planGeneration(request), result, 'Native/WASM machine generator parity');
  for (const file of [...Object.entries(templates('rust')).map(([path,content]) => ({path,content})),...result.files]) {
    const destination = path.join(output,file.path);
    await mkdir(path.dirname(destination),{recursive:true});
    await writeFile(destination,file.content);
  }
  await writeFile(path.join(output,'tests/support/lawspec_generators.rs'),
    'use proptest::prelude::*;\npub fn sizes() -> impl Strategy<Value=isize> { 1isize..10 }\n');
  const run = spawnSync('cargo',['test','--offline','--quiet'],{cwd:output,encoding:'utf8',maxBuffer:32*1024*1024,
    env:{...process.env,CARGO_TARGET_DIR:path.join(root,'.artifacts/rust-native-shapes/target')}});
  const log=(run.stdout ?? '')+(run.stderr ?? '');
  await writeFile(path.join(output,'run.log'),log);
  if (machineBits === nativeBits) assert.equal(run.status,0,log);
  else {
    assert.notEqual(run.status,0);
    assert.match(log,/test result: FAILED/);
    assert.match(log,/machineBits does not match native architecture/);
  }
  console.log(`Rust native generator: ${machineBits}-bit profile ${machineBits === nativeBits ? 'passes' : 'rejects architecture mismatch'}`);
}
