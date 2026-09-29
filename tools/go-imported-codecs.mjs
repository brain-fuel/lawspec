import assert from 'node:assert/strict';
import {execFileSync,spawnSync} from 'node:child_process';
import {mkdir,readFile,writeFile,unlink} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';
const root=path.resolve(import.meta.dirname,'..');
const compiler=process.env.LAWSPEC_CORE;
assert.ok(compiler,'Set LAWSPEC_CORE');
const wasm=await createCompiler();
const read=name=>readFile(path.join(root,'test/fixtures',name==='domain.lawspec'?'native-codecs':'native-go-codecs',name),'utf8');
const content=await read('domain.lawspec');
const nativeBindings=JSON.parse(await read('bindings-go.json'));
const hooks=await read('hooks.go');
const env={...process.env,GOCACHE:path.join(root,'.artifacts/go-cache'),GOTOOLCHAIN:'local',GOPROXY:'off'};
const rapid=path.join(execFileSync('go',['env','GOMODCACHE'],{encoding:'utf8'}).trim(),'pgregory.net/rapid@v1.2.0');
for(const machineBits of [32,64]) for(const minify of [false,true]) {
  const sourceDir=machineBits===32?'library/native':'';
  const directory=path.join(root,`.artifacts/go-imported-codec-hooks/${machineBits}-${minify}`);
  const request={schemaVersion:4,method:'planGeneration',target:'go',machineBits,minify,sourceDir,testDir:sourceDir,
    nativeBindings,generation:{exhaustiveLimit:1},sources:[{path:'codecs.lawspec',content}]};
  const result=JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),encoding:'utf8',maxBuffer:64*1024*1024}));
  assert.deepEqual(result.diagnostics,[]);
  assert.deepEqual(await wasm.planGeneration(request),result,'Go codec native/WASM parity');
  for(const file of result.files) {
    const destination=path.join(directory,file.path);
    await mkdir(path.dirname(destination),{recursive:true});
    await writeFile(destination,file.content);
    if(!minify && file.path.endsWith('lawspec_native_codecs.go'))
      assert.equal(file.content,execFileSync('gofmt',[],{input:file.content,encoding:'utf8'}),file.path);
  }
  const packageDir=path.join(directory,sourceDir,'native/codecs');
  await mkdir(path.join(directory,'model'),{recursive:true});
  await mkdir(path.join(directory,'factories'),{recursive:true});
  await writeFile(path.join(directory,'model/domain.go'),await read('domain.go'));
  await unlink(path.join(packageDir,'shrink_test.go')).catch(error=>{ if(error.code!=='ENOENT') throw error; });
  const hookPath=path.join(packageDir,'hooks.go');
  await writeFile(hookPath,hooks);
  const generatorPath=path.join(directory,'factories/generators.go');
  await writeFile(generatorPath,await read('generators.go'));
  await writeFile(path.join(directory,'go.mod'),`module fixture\n\ngo 1.24.0\n\nrequire pgregory.net/rapid v1.2.0\nreplace pgregory.net/rapid => ${JSON.stringify(rapid)}\n`);
  const build=spawnSync('go',['build','./model','./'+path.join(sourceDir,'native/codecs')],{cwd:directory,env,encoding:'utf8'});
  await writeFile(path.join(directory,'source-build.log'),build.stdout+build.stderr);
  assert.equal(build.status,0,build.stdout+build.stderr);
  async function run(label) {
    const result=spawnSync('go',['test','./...','-rapid.seed=424242','-rapid.nofailfile'],{cwd:directory,env,encoding:'utf8',maxBuffer:32*1024*1024});
    const log=result.stdout+result.stderr;
    await writeFile(path.join(directory,label+'.log'),log);
    return {...result,log};
  }
  const correct=await run('correct');
  assert.equal(correct.status,0,correct.log);
  const shrinkPath=path.join(packageDir,'shrink_test.go');
  await writeFile(shrinkPath,(await read('shrink_test.go')).replace('bits := 64',`bits := ${machineBits}`));
  try {
    const shrunk=await run('shrinking');
    assert.notEqual(shrunk.status,0,shrunk.log);
    assert.match(shrunk.log,/payload 61/);
  } finally { await unlink(shrinkPath); }
  for(const [label,before,after,expected] of [
    ['decoding-error','return model.NewPositive(value.(PositivePositive).Value), nil','return model.Positive{}, fmt.Errorf("custom decoding failed")',/Positive toNative: custom decoding failed/],
    ['encoding-error','return PositivePositive{Value: value.Unpack()}, nil','return nil, fmt.Errorf("custom encoding failed")',/Positive fromNative: custom encoding failed/],
    ['invalid-result','PositivePositive{Value: value.Unpack()}','PositivePositive{Value: 0}',/constructor field contract rejected/],
    ['collapsed-tail','if value.Ended() {','if true {',/flattened recursive representation/],
  ]) {
    assert.ok(hooks.includes(before));
    await writeFile(hookPath,hooks.replace(before,after));
    const failed=await run(label);
    assert.notEqual(failed.status,0,failed.log);
    assert.doesNotMatch(failed.log,/build failed/);
    assert.match(failed.log,expected);
  }
  await writeFile(hookPath,hooks);
  const generators=await read('generators.go');
  await writeFile(generatorPath,generators.replace('Int8Range(1, 100)','Int8Range(0, 0)'));
  const invalid=await run('invalid-generator');
  assert.notEqual(invalid.status,0,invalid.log);
  assert.match(invalid.log,/native generator.*Positive.*constructor field contract rejected/);
  await writeFile(generatorPath,generators);
  console.log(`Go imported-model codec hooks: private products, flat recursion, errors and invalid samples; ${machineBits}, compact=${minify}`);
}
