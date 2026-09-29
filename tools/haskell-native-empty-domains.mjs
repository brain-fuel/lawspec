import assert from 'node:assert/strict';
import {execFileSync,spawnSync} from 'node:child_process';
import {mkdir,writeFile,readFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';
const root=path.resolve(import.meta.dirname,'..');
const compiler=process.env.LAWSPEC_CORE;
const ghc=process.env.LAWSPEC_GHC;
assert.ok(compiler && ghc,'Set LAWSPEC_CORE and LAWSPEC_GHC');
const packageArgs=process.env.LAWSPEC_GHC_PACKAGE_DB?['-package-db',process.env.LAWSPEC_GHC_PACKAGE_DB]:[];
const wasm=await createCompiler();
const source=await readFile(path.join(root,'test/fixtures/native_empty_domains.lawspec'),'utf8');
for(const machineBits of [32,64]) for(const minify of [false,true]){
 const directory=path.join(root,'.artifacts/haskell-native-empty-domains',`${machineBits}-${minify}`);
 await rm(directory,{recursive:true,force:true});
 await mkdir(directory,{recursive:true});
 const sourceDir=machineBits===32?'library/native':'src';
 const testDir=machineBits===32?'checks/native':'test';
 const request={schemaVersion:4,method:'planGeneration',target:'haskell',machineBits,minify,sourceDir,testDir,
  generation:{exhaustiveLimit:1},sources:[{path:'empty.lawspec',content:source}],nativeBindings:{generators:[
   {type:'example.empty::type::Phantom',factory:['Factories','phantoms']},
   {type:'List',factory:['Factories','lists']}]}};
 const result=JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),encoding:'utf8',maxBuffer:32*1024*1024}));
 assert.deepEqual(result.diagnostics,[]);
 assert.deepEqual(await wasm.planGeneration(request),result);
 const put=async(file,content)=>{const dest=path.join(directory,file);await mkdir(path.dirname(dest),{recursive:true});await writeFile(dest,content);};
 for(const file of result.files) await put(file.path,file.content);
 const factory=`module Factories where
import Hedgehog (Gen)
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import qualified LawSpecData as Data

phantoms :: Gen a -> Gen (Data.Phantom a)
phantoms child = Data.PhantomPhantom <$> Gen.int8 (Range.linear 40 100)

lists :: Gen a -> Gen [a]
lists _ = error "finite List Empty must be enumerated"
`;
 const factoryPath=`${testDir}/Factories.hs`;
 await put(factoryPath,factory);
 await put('Main.hs','module Main where\nimport Test.Hspec\nimport qualified Example.EmptySpec as Empty\nmain :: IO ()\nmain = hspec Empty.spec\n');
 const run=label=>{
  const build=spawnSync(ghc,[...packageArgs,'--make','Main.hs',`-i${sourceDir}`,`-i${testDir}`,'-O0','-outputdir','build','-o','check'],
   {cwd:directory,encoding:'utf8',maxBuffer:32*1024*1024});
  assert.equal(build.status,0,build.stdout+build.stderr);
  return spawnSync(path.join(directory,'check'),[],{cwd:directory,encoding:'utf8',maxBuffer:32*1024*1024,timeout:30000});
 };
 const correct=run();await put('correct.log',correct.stdout+correct.stderr);
 assert.equal(correct.status,0,correct.stdout+correct.stderr);
 await put(factoryPath,factory.replace('Data.PhantomPhantom <$> Gen.int8 (Range.linear 40 100)',
  'const (Data.PhantomPhantom 40) <$> child'));
 const impossible=run();await put('impossible.log',impossible.stdout+impossible.stderr);
 assert.notEqual(impossible.status,0);
 assert.match(impossible.stdout+impossible.stderr,/[Gg]ave up/);
 console.log(`Haskell ${machineBits}, minify=${minify}: ignored Empty works, demanded Empty fails, List Empty enumerates`);
}
