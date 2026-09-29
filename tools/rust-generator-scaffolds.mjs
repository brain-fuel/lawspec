// Compile scaffold signatures, then implement native factories without losing shrinking.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile, rm} from 'node:fs/promises';
import path from 'node:path';
import {templates} from '../npm/templates.mjs';
import {createCompiler} from '../npm/api.mjs';
import {planWrites, applyWrites} from '../npm/files.mjs';

const root=path.resolve(import.meta.dirname,'..');
const compiler=process.env.LAWSPEC_CORE;
assert.ok(compiler,'Set LAWSPEC_CORE');
const wasm=await createCompiler();
const fixture=path.join(root,'test/fixtures/native-shapes');
const source=await readFile(path.join(root,'test/fixtures/native_shapes.lawspec'),'utf8');
const bindings=JSON.parse(await readFile(path.join(fixture,'bindings.json'),'utf8'));
bindings.generators=[
  {type:'native.shapes::type::Box',factory:['crate','factories','wrapped'],stub:true},
  {type:'Int8',factory:['crate','factories','bytes'],stub:true},
  {type:'native.shapes::type::Stamp',factory:['self','factories','seals'],stub:true},
];
const targetDir=path.join(root,'.artifacts/rust-generator-scaffolds/target');
const cargo=(directory,args)=>spawnSync('cargo',args,{cwd:directory,encoding:'utf8',maxBuffer:32*1024*1024,
  env:{...process.env,CARGO_TARGET_DIR:targetDir}});
async function plan(request) {
  const result=JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),encoding:'utf8',maxBuffer:32*1024*1024}));
  assert.deepEqual(result.diagnostics,[]);
  assert.deepEqual(await wasm.planGeneration(request),result,'Native/WASM scaffold parity');
  return result.files;
}
async function put(directory,relative,content) {
  const file=path.join(directory,relative);
  await mkdir(path.dirname(file),{recursive:true});
  await writeFile(file,content);
}
async function run(directory,label,args,expected=0) {
  const result=cargo(directory,args);
  const log=(result.stdout??'')+(result.stderr??'');
  await writeFile(path.join(directory,`${label}.log`),log);
  assert.equal(result.status,expected,log);
  return log;
}
for(const machineBits of [32,64]) for(const minify of [false,true]) {
  const directory=path.join(root,'.artifacts/rust-generator-scaffolds',`${machineBits}-${minify}`);
  await rm(directory,{recursive:true,force:true});
  await mkdir(directory,{recursive:true});
  const sourceDir='library/native', testDir='checks/native';
  // These module names contain the suffixes "ls" and "crate". Qualifying the
  // application path must not rewrite those identifier substrings.
  const moduleName=machineBits===32?'tools':'mycrate';
  const nativeBindings=JSON.parse(JSON.stringify(bindings).replaceAll('"domain"',JSON.stringify(moduleName)));
  const request={schemaVersion:4,method:'planGeneration',target:'rust',machineBits,minify,
    sourceDir,testDir,sources:[{path:'shapes.lawspec',content:source}],nativeBindings,
    generation:{exhaustiveLimit:1}};
  const files=await plan(request);
  await applyWrites([await planWrites(directory,files)]);
  const tests=files.filter(file=>file.path.endsWith('_lawspec.rs'));
  await put(directory,'Cargo.toml',templates('rust')['Cargo.toml']+`\n[lib]\npath="${sourceDir}/lib.rs"\n`+
    tests.map((file,index)=>`\n[[test]]\nname="shapes_${index}"\npath="${file.path}"\n`).join(''));
  await put(directory,`${sourceDir}/lib.rs`,'include!("lawspec_modules.rs");\npub mod domain;\n'+
    `pub mod ${moduleName} { pub use super::domain::*; }\n`);
  await put(directory,`${sourceDir}/domain.rs`,await readFile(path.join(fixture,'domain.rs')));
  await run(directory,'source',['check','--offline','--quiet','--lib']);
  await run(directory,'scaffold-compile',['test','--offline','--quiet','--no-run']);
  const failure=await run(directory,'scaffold-failure',['test','--offline','--quiet'],101);
  assert.match(failure,/not implemented: Implement generator for/);
  assert.match(failure,/test result: FAILED/);
  // Record ownership, fill the existing scaffold, then regenerate through the real file planner.
  await applyWrites([await planWrites(directory,files)]);
  const factory=files.find(file=>file.path.endsWith('support/factories.rs'));
  assert.equal(factory.ownership,'user');
  assert.ok(factory.content.includes(`lawspec_example::${moduleName}::Wrapped<T0>`));
  const implementation=await readFile(path.join(fixture,'generators.rs'),'utf8');
  await put(directory,factory.path,implementation);
  const again=await planWrites(directory,files);
  assert.deepEqual(again.adapterUpdates,[]);
  assert.ok(again.preserved.includes(factory.path));
  await applyWrites([again]);
  assert.equal(await readFile(path.join(directory,factory.path),'utf8'),implementation);
  const checks=(await readFile(path.join(root,'test/runtime/RustBoundGenericGeneratorCheck.rs'),'utf8'))
    .replaceAll('lawspec_generators::','factories::');
  for(const file of tests) await put(directory,file.path,file.content+'\n'+checks);
  await run(directory,'implemented',['test','--offline','--quiet']);
  for(const file of tests) await put(directory,file.path,file.content);
  const importOnly=await plan({...request,nativeBindings:{...nativeBindings,
    generators:nativeBindings.generators.map(binding=>({...binding,stub:false}))}});
  assert.ok(!importOnly.some(file=>file.path===factory.path));
  await applyWrites([await planWrites(directory,importOnly)]);
  assert.equal(await readFile(path.join(directory,factory.path),'utf8'),implementation);
  await run(directory,'import-only',['test','--offline','--quiet']);
  console.log(`Rust ${machineBits}, minify=${minify}: scaffolds compile, fail until implemented, retain native shrinking and user ownership`);
}

// Every scalar and parametric built-in has a compilable signature, including
// unused factories, raw-keyword module names, and nested namespaces.
const scalars=['Bool',...['Int','UInt'].flatMap(prefix=>[8,16,32,64].map(width=>prefix+width)),
  'IntSize','UIntSize','UIntPtr','Integer','BigInt','BigUInt','Decimal','Rational',
  'Float32','Float64','Complex64','Complex128','Char','CodePoint','CodeUnit16',
  'Text','CodePointText','Utf16Text','Bytes','Symbol','Unit','Null','Undefined'];
const generators=[...scalars,...['List','Maybe','Either','Nullable','Optional']].map((type,index)=>({
  type,factory:['type','nested',`factory_${index}`],stub:true,
}));
generators.push({type:'catalog::type::Wrap',factory:['type','canonical','wrap'],stub:true});
for(const machineBits of [32,64]) {
  const directory=path.join(root,'.artifacts/rust-generator-scaffolds',`catalog-${machineBits}`);
  const files=await plan({schemaVersion:4,method:'planGeneration',target:'rust',machineBits,
    sources:[{path:'catalog.lawspec',content:'unit catalog\ntype Wrap (a :: Type) is Wrap value :: a end'}],
    nativeBindings:{rustCrate:'lawspec_example',generators}});
  for(const [file,content] of Object.entries(templates('rust'))) await put(directory,file,content);
  for(const file of files) await put(directory,file.path,file.content);
  await run(directory,'catalog-compile',['test','--offline','--quiet','--no-run']);
  assert.match(files.find(file=>file.path.endsWith('support/type.rs')).content,/pub mod nested/);
  assert.match(files.find(file=>file.path.endsWith('_lawspec.rs')).content,/mod r#type;/);
  console.log(`Rust ${machineBits}: all scalar and container scaffold signatures compile`);
}
