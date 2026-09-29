import assert from 'node:assert/strict';
import {execFileSync,spawnSync} from 'node:child_process';
import {mkdir,writeFile,readFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';
import {templates} from '../npm/templates.mjs';
const root=path.resolve(import.meta.dirname,'..');
const compiler=process.env.LAWSPEC_CORE;
assert.ok(compiler,'Set LAWSPEC_CORE');
const wasm=await createCompiler();
const source=await readFile(path.join(root,'test/fixtures/native_empty_domains.lawspec'),'utf8');
for(const machineBits of [32,64]) for(const minify of [false,true]){
 const directory=path.join(root,'.artifacts/rust-native-empty-domains',`${machineBits}-${minify}`);
 await rm(directory,{recursive:true,force:true});
 await mkdir(directory,{recursive:true});
 const sourceDir=machineBits===32?'library/native':'src';
 const testDir=machineBits===32?'checks/native':'tests';
 const request={schemaVersion:4,method:'planGeneration',target:'rust',machineBits,minify,sourceDir,testDir,
  generation:{exhaustiveLimit:1},sources:[{path:'empty.lawspec',content:source}],nativeBindings:{rustCrate:'lawspec_example',generators:[
   {type:'example.empty::type::Phantom',factory:['lawspec_generators','phantoms']},
   {type:'List',factory:['lawspec_generators','lists']}]}};
 const result=JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),encoding:'utf8',maxBuffer:32*1024*1024}));
 assert.deepEqual(result.diagnostics,[]);
 assert.deepEqual(await wasm.planGeneration(request),result);
 const put=async(file,content)=>{const dest=path.join(directory,file);await mkdir(path.dirname(dest),{recursive:true});await writeFile(dest,content);};
 for(const file of result.files) await put(file.path,file.content);
 const tests=result.files.filter(file=>file.path.endsWith('_lawspec.rs'));
 await put('Cargo.toml',templates('rust')['Cargo.toml']+`\n[lib]\npath="${sourceDir}/lib.rs"\n`+
  tests.map((file,index)=>`\n[[test]]\nname="empty_${index}"\npath="${file.path}"\n`).join(''));
 await put(`${sourceDir}/lib.rs`,'include!("lawspec_modules.rs");\n');
 const factory=`use lawspec_example::lawspec_data::Phantom;
use proptest::prelude::*;

pub fn phantoms<T: std::fmt::Debug + 'static>(
    _argument: BoxedStrategy<T>,
) -> BoxedStrategy<Phantom<T>> {
    (40i8..100).prop_map(|value| Phantom::Phantom {
        value,
        _lawspec_marker: std::marker::PhantomData,
    }).boxed()
}

pub fn lists<T: std::fmt::Debug + 'static>(
    _argument: BoxedStrategy<T>,
) -> BoxedStrategy<Vec<T>> {
    panic!("finite List Empty must be enumerated")
}
`;
 const factoryPath=`${testDir}/support/lawspec_generators.rs`;
 await put(factoryPath,factory);
 const run=()=>spawnSync('cargo',['test','--offline','--quiet'],{cwd:directory,encoding:'utf8',maxBuffer:32*1024*1024,
  env:{...process.env,CARGO_TARGET_DIR:path.join(root,'.artifacts/rust-native-empty-domains/target')}});
 const correct=run();await put('correct.log',correct.stdout+correct.stderr);
 assert.equal(correct.status,0,correct.stdout+correct.stderr);
 assert.match(correct.stdout,/test result: ok/);
 await put(factoryPath,factory.replace('(40i8..100).prop_map(|value|','_argument.prop_map(|_|').replace('        value,','        value: 40,'));
 const impossible=run();await put('impossible.log',impossible.stdout+impossible.stderr);
 assert.notEqual(impossible.status,0);
 assert.match(impossible.stdout+impossible.stderr,/test result: FAILED/);
 assert.match(impossible.stdout+impossible.stderr,/Too many local rejects|no native generator argument/);
 console.log(`Rust ${machineBits}, minify=${minify}: ignored Empty works, demanded Empty fails, List Empty enumerates`);
}
