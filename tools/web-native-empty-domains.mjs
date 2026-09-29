import assert from 'node:assert/strict';
import {execFileSync,spawnSync} from 'node:child_process';
import {mkdir,writeFile,readFile,rm,symlink} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';
const root=path.resolve(import.meta.dirname,'..');
const compiler=process.env.LAWSPEC_CORE;
assert.ok(compiler,'Set LAWSPEC_CORE');
const wasm=await createCompiler();
const source=await readFile(path.join(root,'test/fixtures/native_empty_domains.lawspec'),'utf8');
for(const target of ['javascript','typescript']) for(const machineBits of [32,64]) for(const minify of [false,true]){
 const directory=path.join(root,'.artifacts/web-native-empty-domains',`${target}-${machineBits}-${minify}`);
 await rm(directory,{recursive:true,force:true});await mkdir(directory,{recursive:true});
 const sourceDir=machineBits===32?'library':'src';
 const testDir=machineBits===32?'checks':'test';
 const ts=target==='typescript',ext=ts?'ts':'mjs',importExt=ts?'js':'mjs';
 const request={schemaVersion:4,method:'planGeneration',target,machineBits,minify,sourceDir,testDir,
  generation:{exhaustiveLimit:1},sources:[{path:'empty.lawspec',content:source}],nativeBindings:{generators:[
   {type:'example.empty::type::Phantom',factory:['factories','phantoms']},{type:'List',factory:['factories','lists']}]}};
 const result=JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),encoding:'utf8',maxBuffer:32*1024*1024}));
 assert.deepEqual(result.diagnostics,[]);assert.deepEqual(await wasm.planGeneration(request),result);
 const put=async(file,content)=>{const dest=path.join(directory,file);await mkdir(path.dirname(dest),{recursive:true});await writeFile(dest,content);};
 for(const file of result.files) await put(file.path,file.content);
 await put('package.json','{"type":"module"}\n');
 await put('tsconfig.json',JSON.stringify({compilerOptions:{target:'ES2022',module:'NodeNext',strict:true,skipLibCheck:true,rootDir:'.',outDir:'dist'},include:[`${sourceDir}/**/*.ts`,`${testDir}/**/*.ts`]}));
 await symlink(path.join(root,'.artifacts/lists/javascript/node_modules'),path.join(directory,'node_modules'));
 const generic=ts?'<T>':'';
 const argument=ts?'child: fc.Arbitrary<T>':'child';
 const factory=`import * as fc from 'fast-check';
import * as data from '../${sourceDir}/lawspec_data.${importExt}';

export function phantoms${generic}(${argument})${ts?': fc.Arbitrary<data.Phantom<T>>':''} {
  return fc.integer({min:40,max:100}).map(value => new data.PhantomPhantom${generic}(value));
}

export function lists${generic}(${argument})${ts?': fc.Arbitrary<T[]>':''} {
  throw new Error('finite List Empty must be enumerated');
}
`;
 const factoryPath=`${testDir}/factories.${ext}`;
 const tests=result.files.filter(file=>file.path.includes('.lawspec.test.')).map(file=>ts?'dist/'+file.path.replace(/\.ts$/,'.js'):file.path);
 const run=()=>{
  if(ts) execFileSync(process.execPath,[path.join(root,'.artifacts/web-data-deps/typescript/bin/tsc'),'-p',directory],{encoding:'utf8'});
  return spawnSync(process.execPath,['--test',...tests],{cwd:directory,encoding:'utf8',timeout:30000,maxBuffer:32*1024*1024});
 };
 await put(factoryPath,factory);
 const correct=run();await put('correct.log',correct.stdout+correct.stderr);assert.equal(correct.status,0,correct.stdout+correct.stderr);
 await put(factoryPath,factory.replace('fc.integer({min:40,max:100}).map(value =>','child.map(_ =>').replace(`${generic}(value)`,`${generic}(40)`));
 const impossible=run();await put('impossible.log',impossible.stdout+impossible.stderr);
 assert.equal(impossible.error,undefined);assert.notEqual(impossible.status,0);
 assert.match(impossible.stdout+impossible.stderr,/no native generator argument.*Empty/);
 console.log(`${target} ${machineBits}, minify=${minify}: ignored Empty works, demanded Empty fails promptly, List Empty enumerates`);
}
