import assert from 'node:assert/strict';
import {execFileSync,spawnSync} from 'node:child_process';
import {mkdir,readFile,writeFile,unlink} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';
const root=path.resolve(import.meta.dirname,'..');
const compiler=process.env.LAWSPEC_CORE;
assert.ok(compiler,'Set LAWSPEC_CORE');
const wasm=await createCompiler();
const read=name=>readFile(path.join(root,'test/fixtures/native-go-names',name),'utf8');
const content=await read('domain.lawspec');
const nativeBindings=JSON.parse(await read('bindings.json'));
const env={...process.env,GOCACHE:path.join(root,'.artifacts/go-cache'),GOTOOLCHAIN:'local',GOPROXY:'off'};
const rapid=path.join(execFileSync('go',['env','GOMODCACHE'],{encoding:'utf8'}).trim(),'pgregory.net/rapid@v1.2.0');
for(const machineBits of [32,64]) for(const minify of [false,true]) {
  const sourceDir=machineBits===32?'library/native':'';
  const directory=path.join(root,`.artifacts/go-native-name-collisions/${machineBits}-${minify}`);
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
  const packageDir=path.join(directory,sourceDir,'collision/model');
  await writeFile(path.join(packageDir,'domain.go'),await read('domain.go'));
  const generatorPath=path.join(packageDir,'native_generators_test.go');
  await writeFile(generatorPath,await read('generators.go'));
  await writeFile(path.join(directory,'go.mod'),`module fixture\n\ngo 1.24.0\n\nrequire pgregory.net/rapid v1.2.0\nreplace pgregory.net/rapid => ${JSON.stringify(rapid)}\n`);
  const build=spawnSync('go',['build','./...'],{cwd:directory,env,encoding:'utf8'});
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
  const data=result.files.find(file=>file.path.endsWith('/lawspec_data.go')).content;
  assert.match(data,/type Canonical1Box\[/);
  assert.match(data,/type CanonicalBox interface/);
  assert.match(data,/type CanonicalTree\[/);
  assert.ok(result.files.some(file=>file.content.includes('collision.model::type::Box')));
  const domain=await read('domain.go');
  await writeFile(path.join(packageDir,'domain.go'),domain.replace('return value','var zero T; return zero'));
  const failed=await run('wrong-adapter');
  assert.notEqual(failed.status,0,failed.log);
  assert.doesNotMatch(failed.log,/build failed/);
  console.log(`Go canonical name collisions: recursive and generic application types, occupied prefix, native generator and rejected adapter; ${machineBits}, compact=${minify}`);
}
