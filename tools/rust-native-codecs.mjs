import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {templates} from '../npm/templates.mjs';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const {createCompiler} = await import('../npm/api.mjs');
const wasm = await createCompiler();
assert.ok(compiler, 'Set LAWSPEC_CORE');
const read = name => readFile(path.join(root, 'test/fixtures/native-codecs', name), 'utf8');
const bindings = JSON.parse(await read('bindings-rust.json'));
const content = await read('domain.lawspec');
const codecs = await read('codecs.rs');
for (const machineBits of [32,64]) for (const minify of [false,true]) {
  const sourceDir = machineBits === 32 ? 'library/native' : 'src';
  const testDir = machineBits === 32 ? 'checks/native' : 'tests';
  const directory = path.join(root, `.artifacts/rust-native-codecs/${machineBits}-${minify}`);
  const request = {schemaVersion:4, method:'planGeneration', target:'rust', machineBits, minify,
    sourceDir,testDir, nativeBindings:bindings,generation:{exhaustiveLimit:1},sources:[{path:'codecs.lawspec',content}]};
  const result = JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),encoding:'utf8',maxBuffer:64*1024*1024}));
  assert.deepEqual(result.diagnostics,[]);
  assert.deepEqual(await wasm.planGeneration(request),result,'Rust codec native/WASM parity');
  for (const file of result.files) {
    const destination = path.join(directory,file.path);
    await mkdir(path.dirname(destination),{recursive:true});
    await writeFile(destination,file.content);
  }
  const tests = result.files.filter(file => file.path.endsWith('_lawspec.rs'));
  const shrinkCheck = await readFile(path.join(root,'test/runtime/RustBoundCodecGeneratorCheck.rs'),'utf8');
  for (const file of tests) await writeFile(path.join(directory,file.path),file.content + '\n' +
    shrinkCheck.replace('        64,','        ' + machineBits + ','));
  await writeFile(path.join(directory,'Cargo.toml'),templates('rust')['Cargo.toml'] +
    `\n[lib]\npath="${sourceDir}/lib.rs"\n` + tests.map((file,index) =>
      `\n[[test]]\nname="codecs_${index}"\npath="${file.path}"\n`).join(''));
  await writeFile(path.join(directory,sourceDir,'lib.rs'),'include!("lawspec_modules.rs");\npub mod domain;\npub mod codecs;\n');
  await writeFile(path.join(directory,sourceDir,'domain.rs'),await read('domain.rs'));
  const codecPath = path.join(directory,sourceDir,'codecs.rs');
  await writeFile(codecPath,codecs);
  await writeFile(path.join(directory,testDir,'support/lawspec_generators.rs'),await read('generators.rs'));
  const options = {cwd:directory,encoding:'utf8',maxBuffer:32*1024*1024,
    env:{...process.env,CARGO_TARGET_DIR:path.join(root,'.artifacts/rust-native-codecs/target')}};
  execFileSync('cargo',['check','--offline','--quiet','--lib'],options);
  async function run(label) {
    const test = spawnSync('cargo',['test','--offline','--quiet'],options);
    const log = (test.stdout ?? '')+(test.stderr ?? '');
    await writeFile(path.join(directory,`${label}.log`),log);
    return {...test,log};
  }
  const correct = await run('correct');
  assert.equal(correct.status,0,correct.log);
  for (const [label,before,after,expected] of [
    ['hook-error','Ok(domain::Positive::new(value))','Err("custom decoding failed".into())',/native codec native.codecs::type::Positive toNative: custom decoding failed/],
    ['encoding-error','Ok(data::Positive::Positive {\n        value: value.into_inner(),\n    })','Err("custom encoding failed".into())',/native codec native.codecs::type::Positive fromNative: custom encoding failed/],
    ['invalid-result','value: value.into_inner(),','value: 0,',/field refinement 1 failed/],
  ]) {
    assert.ok(codecs.includes(before),before);
    await writeFile(codecPath,codecs.replace(before,after));
    execFileSync('cargo',['check','--offline','--quiet','--lib'],options);
    const wrong = await run(label);
    assert.notEqual(wrong.status,0);
    assert.match(wrong.log,/test result: FAILED/);
    assert.match(wrong.log,expected);
  }
  await writeFile(codecPath,codecs);
  const generatorPath = path.join(directory,testDir,'support/lawspec_generators.rs');
  const generators = await read('generators.rs');
  assert.ok(generators.includes('(1i8..100).prop_map(domain::Positive::new)'));
  await writeFile(generatorPath,generators.replace('(1i8..100).prop_map(domain::Positive::new)',
    'Just(domain::Positive::new(0))'));
  const invalidGenerator = await run('invalid-generator');
  assert.notEqual(invalidGenerator.status,0);
  assert.match(invalidGenerator.log,/field refinement 1 failed/);
  await writeFile(generatorPath,generators);
  console.log(`Rust codec hooks: private products, flattened recursion, generic generators and rejected errors/results; ${machineBits}, compact=${minify}`);
}
