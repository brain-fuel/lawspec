// Compile and execute Java application codec hooks with native JetCheck factories.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {templates} from '../npm/templates.mjs';
import {createCompiler} from '../npm/api.mjs';
const root=path.resolve(import.meta.dirname,'..');
const compiler=process.env.LAWSPEC_CORE;
assert.ok(compiler,'Set LAWSPEC_CORE');
const wasm=await createCompiler();
const read=name=>readFile(path.join(root,'test/fixtures/native-codecs',name),'utf8');
const nativeBindings=JSON.parse(await read('bindings-java.json'));
const content=(await read('domain.lawspec')).replaceAll('native.codecs','bound.codecs');
const hooks=await read('CodecHooks.java');
for (const machineBits of [32,64]) for (const minify of [false,true]) {
  const sourceDir=machineBits===32 ? 'library/native' : 'src/main/java';
  const testDir=machineBits===32 ? 'checks/native' : 'src/test/java';
  const directory=path.join(root,`.artifacts/java-native-codec-hooks/${machineBits}-${minify}`);
  const request={schemaVersion:4,method:'planGeneration',target:'java',machineBits,minify,
    sourceDir,testDir,nativeBindings,generation:{exhaustiveLimit:1},sources:[{path:'codecs.lawspec',content}]};
  const result=JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),encoding:'utf8',maxBuffer:64*1024*1024}));
  assert.deepEqual(result.diagnostics,[]);
  assert.deepEqual(await wasm.planGeneration(request),result,'Java codec native/WASM parity');
  for (const file of result.files) {
    const destination=path.join(directory,file.path);
    await mkdir(path.dirname(destination),{recursive:true});
    await writeFile(destination,file.content);
  }
  for (const [name,source] of Object.entries(templates('java'))) {
    const destination=path.join(directory,name);
    await mkdir(path.dirname(destination),{recursive:true});
    await writeFile(destination,name==='pom.xml' ? source.replace('<build>',
      `<build><sourceDirectory>${sourceDir}</sourceDirectory><testSourceDirectory>${testDir}</testSourceDirectory>`) : source);
  }
  for (const name of ['CodecDomain.java','CodecHooks.java']) {
    await mkdir(path.join(directory,sourceDir,'domain'),{recursive:true});
    await writeFile(path.join(directory,sourceDir,'domain',name),await read(name));
  }
  const generatorPath=path.join(directory,testDir,'domain','CodecGenerators.java');
  await mkdir(path.dirname(generatorPath),{recursive:true});
  await writeFile(generatorPath,await read('CodecGenerators.java'));
  const run=async (label,phase='test')=>{
    const execution=spawnSync('mvn',['-o','-q',phase],{cwd:directory,encoding:'utf8',maxBuffer:32*1024*1024});
    const log=(execution.stdout??'')+(execution.stderr??'');
    await writeFile(path.join(directory,`${label}.log`),log);
    return {...execution,log};
  };
  const source=await run('source-only','compile');
  assert.equal(source.status,0,source.log);
  await writeFile(path.join(directory,'JavaCodecBindingsCheck.java'),
    await readFile(path.join(root,'test/runtime/JavaCodecBindingsCheck.java')));
  execFileSync('javac',['-cp','target/classes','-d','target/source-check','JavaCodecBindingsCheck.java'],{cwd:directory,encoding:'utf8'});
  const sourceCheck=execFileSync('java',['-cp','target/classes'+path.delimiter+'target/source-check',
    'JavaCodecBindingsCheck',String(machineBits)],{cwd:directory,encoding:'utf8'});
  await writeFile(path.join(directory,'source-check.log'),sourceCheck);
  await mkdir(path.join(directory,testDir,'bound'),{recursive:true});
  await writeFile(path.join(directory,testDir,'bound/JavaBoundCodecGeneratorTest.java'),
    await readFile(path.join(root,'test/runtime/JavaBoundCodecGeneratorTest.java')));
  const correct=await run('correct');
  assert.equal(correct.status,0,correct.log);
  const hookPath=path.join(directory,sourceDir,'domain','CodecHooks.java');
  for (const [label,before,after,expected] of [
    ['decoding-error','return new CodecDomain.Positive(((Positive.PositiveCase) value).value);','throw new IllegalArgumentException("custom decoding failed");',/Positive toNative: custom decoding failed/],
    ['encoding-error','return new Positive.PositiveCase(value.unpack());','throw new IllegalArgumentException("custom encoding failed");',/Positive fromNative: custom encoding failed/],
    ['invalid-result','new Positive.PositiveCase(value.unpack())','new Positive.PositiveCase((byte) 0)',/field refinement 1 failed/],
    ['collapsed-tail','value.ended()','true',/flattened recursive representation/],
  ]) {
    assert.ok(hooks.includes(before));
    await writeFile(hookPath,hooks.replace(before,after));
    const failed=await run(label);
    assert.notEqual(failed.status,0,failed.log);
    assert.doesNotMatch(failed.log,/COMPILATION ERROR/);
    assert.match(failed.log,expected);
  }
  await writeFile(hookPath,hooks);
  const generators=await read('CodecGenerators.java');
  await writeFile(generatorPath,generators.replace('integers(1, 100).map(value -> new CodecDomain.Positive',
    'integers(0, 0).map(value -> new CodecDomain.Positive'));
  const invalid=await run('invalid-generator');
  assert.notEqual(invalid.status,0,invalid.log);
  assert.doesNotMatch(invalid.log,/COMPILATION ERROR/);
  assert.match(invalid.log,/native generator.*Positive.*field refinement 1 failed/);
  await writeFile(generatorPath,generators);
  console.log(`Java codec hooks: private products, flattened recursion, generic converters and rejected mutants; ${machineBits}, compact=${minify}`);
}
