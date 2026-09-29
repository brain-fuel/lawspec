import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const ghc = process.env.LAWSPEC_GHC;
assert.ok(compiler && ghc, 'Set LAWSPEC_CORE and LAWSPEC_GHC');
const packageArgs = process.env.LAWSPEC_GHC_PACKAGE_DB ? ['-package-db',process.env.LAWSPEC_GHC_PACKAGE_DB] : [];
const read = name => readFile(path.join(root,'test/fixtures/native-codecs',name),'utf8');
const bindings = JSON.parse(await read('bindings-haskell.json'));
const content = await read('domain.lawspec');
const {createCompiler} = await import('../npm/api.mjs');
const wasm = await createCompiler();
const hooks = await read('CodecHooks.hs');
for (const machineBits of [32,64]) for (const minify of [false,true]) {
  const sourceDir = machineBits === 32 ? 'library/native' : 'src';
  const testDir = machineBits === 32 ? 'checks/native' : 'test';
  const directory = path.join(root,`.artifacts/haskell-native-codec-hooks/${machineBits}-${minify}`);
  const request = {schemaVersion:4,method:'planGeneration',target:'haskell',machineBits,minify,
    sourceDir,testDir,nativeBindings:bindings,generation:{exhaustiveLimit:1},sources:[{path:'codecs.lawspec',content}]};
  const result = JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),encoding:'utf8',maxBuffer:64*1024*1024}));
  assert.deepEqual(await wasm.planGeneration(request), result, 'Haskell codec hooks native/WASM parity');
  assert.deepEqual(result.diagnostics,[]);
  for (const file of result.files) {
    const destination = path.join(directory,file.path);
    await mkdir(path.dirname(destination),{recursive:true});
    await writeFile(destination,file.content);
  }
  for (const name of ['CodecDomain.hs','CodecHooks.hs']) await writeFile(path.join(directory,sourceDir,name),await read(name));
  const generatorPath = path.join(directory,testDir,'CodecGenerators.hs');
  await writeFile(generatorPath,await read('CodecGenerators.hs'));
  await writeFile(path.join(directory,'HaskellBoundCodecGeneratorsCheck.hs'), await readFile(path.join(root,'test/runtime/HaskellBoundCodecGeneratorsCheck.hs'),'utf8'));
  await writeFile(path.join(directory,'Main.hs'),`module Main where\nimport Test.Hspec\nimport qualified Native.CodecsSpec as C\nimport HaskellBoundCodecGeneratorsCheck (checkFactories)\nmain = checkFactories ${machineBits} >> hspec C.spec\n`);
  const options = {cwd:directory,encoding:'utf8',maxBuffer:32*1024*1024};
  const sourceBuild = spawnSync(ghc,['--make','-fno-code','-hide-all-packages','-package','base','-package','text','-package','bytestring',
    `-i${sourceDir}`,'-outputdir','source-build',...result.files.filter(file=>file.placement==='source').map(file=>file.path)],options);
  await writeFile(path.join(directory,'source-build.log'),sourceBuild.stdout+sourceBuild.stderr);
  assert.equal(sourceBuild.status,0,sourceBuild.stdout+sourceBuild.stderr);
  async function run(label) {
    const build = spawnSync(ghc,[...packageArgs,'--make','Main.hs',`-i${sourceDir}`,`-i${testDir}`,'-O0','-outputdir','build','-o','check'],options);
    await writeFile(path.join(directory,`${label}-build.log`),build.stdout+build.stderr);
    assert.equal(build.status,0,build.stdout+build.stderr);
    const test = spawnSync(path.join(directory,'check'),[],options);
    const log = test.stdout+test.stderr;
    await writeFile(path.join(directory,`${label}.log`),log);
    return {...test,log};
  }
  const correct = await run('correct');
  assert.equal(correct.status,0,correct.log);
  const hookPath = path.join(directory,sourceDir,'CodecHooks.hs');
  for (const [label,before,after,expected] of [
    ['decoding-error','Right (Domain.positive value)','Left "custom decoding failed"',/native codec native.codecs::type::Positive toNative: custom decoding failed/],
    ['encoding-error','Right (Data.PositivePositive (Domain.unpositive value))','Left "custom encoding failed"',/native codec native.codecs::type::Positive fromNative: custom encoding failed/],
    ['invalid-result','Domain.unpositive value','0',/constructor field contract rejected/],
    ['collapsed-tail','if ended then Just Data.ChainStop else Nothing','Just Data.ChainStop',/Failures:[\s\S]*flattened recursive representation example no tail/],
  ]) {
    assert.ok(hooks.includes(before));
    await writeFile(hookPath,hooks.replace(before,after));
    const failed = await run(label);
    assert.notEqual(failed.status,0);
    assert.match(failed.log,expected);
  }
  await writeFile(hookPath,hooks);
  const generators = await read('CodecGenerators.hs');
  await writeFile(generatorPath,generators.replace('Gen.int8 (Range.linear 1 100)','pure 0'));
  const invalidGenerator = await run('invalid-generator');
  assert.notEqual(invalidGenerator.status,0);
  assert.match(invalidGenerator.log,/native generator:.*constructor field contract rejected/s);
  await writeFile(generatorPath,generators);
  console.log(`Haskell codec hooks: private products, flat recursion, nested generics, errors and invalid native samples; ${machineBits}, compact=${minify}`);
}
