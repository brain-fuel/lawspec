import assert from 'node:assert/strict';
import {execFileSync,spawnSync} from 'node:child_process';
import {mkdir,writeFile,readFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';
const root=path.resolve(import.meta.dirname,'..');
const compiler=process.env.LAWSPEC_CORE;
assert.ok(compiler,'Set LAWSPEC_CORE');
const wasm=await createCompiler();
const source=await readFile(path.join(root,'test/fixtures/native_empty_domains.lawspec'),'utf8');
const rapid=process.env.LAWSPEC_RAPID ?? path.join(execFileSync('go',['env','GOMODCACHE'],{encoding:'utf8'}).trim(),'pgregory.net/rapid@v1.2.0');
const env={...process.env,GOCACHE:path.join(root,'.artifacts/go-cache'),GOTOOLCHAIN:'local',GOPROXY:'off'};
for(const machineBits of [32,64]) for(const minify of [false,true]){
 const directory=path.join(root,'.artifacts/go-native-empty-domains',`${machineBits}-${minify}`);
 await rm(directory,{recursive:true,force:true});
 await mkdir(directory,{recursive:true});
 const sourceDir=machineBits===32?'library/native':'';
 const request={schemaVersion:4,method:'planGeneration',target:'go',machineBits,minify,sourceDir,testDir:sourceDir,
  generation:{exhaustiveLimit:1},sources:[{path:'empty.lawspec',content:source}],nativeBindings:{generators:[
   {type:'example.empty::type::Phantom',factory:['NativePhantoms']},
   {type:'List',factory:['NativeLists']}]}};
 const result=JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),encoding:'utf8',maxBuffer:32*1024*1024}));
 assert.deepEqual(result.diagnostics,[]);
 assert.deepEqual(await wasm.planGeneration(request),result);
 const put=async(file,content)=>{const dest=path.join(directory,file);await mkdir(path.dirname(dest),{recursive:true});await writeFile(dest,content);};
 for(const file of result.files) await put(file.path,file.content);
 await put('go.mod',`module fixture\n\ngo 1.22\n\nrequire pgregory.net/rapid v1.2.0\nreplace pgregory.net/rapid => ${JSON.stringify(rapid)}\n`);
 const factory=`package empty

import "pgregory.net/rapid"

func NativePhantoms[T any](child *rapid.Generator[T]) *rapid.Generator[Phantom[T]] {
    return rapid.Map(rapid.IntRange(40, 100), func(value int) Phantom[T] {
        return PhantomPhantom[T]{Value: int8(value)}
    })
}

func NativeLists[T any](child *rapid.Generator[T]) *rapid.Generator[[]T] {
    panic("finite List Empty must be enumerated")
}
`;
 const factoryPath=path.posix.join(sourceDir,'example/empty/native_generators_test.go');
 await put(factoryPath,execFileSync('gofmt',[],{input:factory,encoding:'utf8'}));
 const run=()=>spawnSync('go',['test','./...','-count=1','-rapid.seed=424242','-rapid.nofailfile'],
  {cwd:directory,env,encoding:'utf8',maxBuffer:32*1024*1024,timeout:60000});
 const correct=run();await put('correct.log',correct.stdout+correct.stderr);
 assert.equal(correct.status,0,correct.stdout+correct.stderr);
 await put(factoryPath,factory.replace('rapid.IntRange(40, 100), func(value int)', 'child, func(_ T)').replace('Value: int8(value)','Value: 40'));
 const impossible=run();await put('impossible.log',impossible.stdout+impossible.stderr);
 assert.equal(impossible.error,undefined);
 assert.notEqual(impossible.status,0);
 assert.match(impossible.stdout+impossible.stderr,/only generated 0 valid tests/);
 console.log(`Go ${machineBits}, minify=${minify}: ignored Empty works, demanded Empty fails, List Empty enumerates`);
}
