// Compile Hedgehog factory signatures and verify explicit unimplemented failures.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, writeFile, rm} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';
const root=path.resolve(import.meta.dirname,'..');
const compiler=process.env.LAWSPEC_CORE;
const ghc=process.env.LAWSPEC_GHC;
assert.ok(compiler && ghc,'Set LAWSPEC_CORE and LAWSPEC_GHC');
const packageArgs=process.env.LAWSPEC_GHC_PACKAGE_DB ? ['-package-db',process.env.LAWSPEC_GHC_PACKAGE_DB] : [];
const wasm=await createCompiler();
const scalars=['Bool',...['Int','UInt'].flatMap(prefix=>[8,16,32,64].map(width=>prefix+width)),
  'IntSize','UIntSize','UIntPtr','Integer','BigInt','BigUInt','Decimal','Rational',
  'Float32','Float64','Complex64','Complex128','Char','CodePoint','CodeUnit16',
  'Text','CodePointText','Utf16Text','Bytes','Symbol','Unit','Null','Undefined'];
const types=[...scalars,'List Int8','Maybe Int8','Either Int8 Text','Nullable Int8','Optional Int8','Wrap Int8','Box Int8'];
const generators=types.map(type=>({type:['Wrap','Box'].includes(type.split(' ')[0])
  ? `catalog::type::${type.split(' ')[0]}`:type.split(' ')[0],
  factory:type==='Unit'?['P','error']:['Application','Factories',`native${type.split(' ')[0]}`],stub:true}));
const source='unit catalog\ntype Wrap (a :: Type) is Wrap value :: a end\ntype Box (a :: Type) is Box value :: a end\n'+
  types.map((type,index)=>`law \`catalog ${index}\` is definition is \`for all\` (x :: ${type}) . true end end`).join('\n');
for(const machineBits of [32,64]) for(const minify of [false,true]) {
  const directory=path.join(root,'.artifacts/haskell-generator-scaffolds',`${machineBits}-${minify}`);
  await rm(directory,{recursive:true,force:true});
  await mkdir(directory,{recursive:true});
  const sourceDir='library/native',testDir='checks/native';
  const request={schemaVersion:4,method:'planGeneration',target:'haskell',machineBits,minify,sourceDir,testDir,
    sources:[{path:'catalog.lawspec',content:source}],nativeBindings:{generators,types:[
      {type:'catalog::type::Box',native:['Model','NativeBox'],constructors:[
        {constructor:'Box',native:['Model','NativeBox'],style:'record',fields:[{field:'value',native:'unBox'}]}]}]}};
  const result=JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),encoding:'utf8',maxBuffer:64*1024*1024}));
  assert.deepEqual(result.diagnostics,[]);
  assert.deepEqual(await wasm.planGeneration(request),result);
  const put=async(relative,content)=>{
    const file=path.join(directory,relative);
    await mkdir(path.dirname(file),{recursive:true});
    await writeFile(file,content);
  };
  for(const file of result.files) await put(file.path,file.content);
  const stub=result.files.find(file=>file.path.endsWith('/Application/Factories.hs'));
  assert.equal(stub.ownership,'user');
  assert.match(stub.content,/nativeBox :: H.Gen a0 -> H.Gen \(NativeModule0.NativeBox a0\)/);
  assert.ok(stub.content.split('\n').every(line=>line.length<=80));
  await put(`${sourceDir}/Model.hs`,'module Model where\nnewtype NativeBox a = NativeBox { unBox :: a } deriving (Eq, Show)\n');
  const includes=[`-i${sourceDir}`,`-i${testDir}`];
  const run=(args)=>execFileSync(ghc,args,{cwd:directory,encoding:'utf8',maxBuffer:32*1024*1024});
  run(['--make','-fno-code','-hide-all-packages','-package','base','-package','text','-package','bytestring',
    ...includes,'-outputdir','source-build',...result.files.filter(file=>file.placement==='source').map(file=>file.path)]);
  run([...packageArgs,'--make','-fno-code',...includes,'-outputdir','compile-build',...result.files.map(file=>file.path)]);
  await put('Main.hs',`module Main where
import Control.Exception (SomeException, evaluate, try)
import Data.List (isInfixOf)
import Data.Int (Int8)
import Hedgehog (Gen)
import qualified Application.Factories as F
import qualified P as Edge
import qualified LawSpecData as D
import qualified Model
box :: Gen Int8 -> Gen (Model.NativeBox Int8)
box = F.nativeBox
canonical :: Gen Int8 -> Gen (D.Wrap Int8)
canonical = F.nativeWrap
list :: Gen Int8 -> Gen [Int8]
list = F.nativeList
main :: IO ()
main = mapM_ check [evaluate F.nativeInt8 >> pure (), evaluate Edge.error >> pure (),
  evaluate (F.nativeBox (pure (0 :: Int8))) >> pure (),
  evaluate (F.nativeEither (pure (0 :: Int8)) (pure ())) >> pure ()]
  where
    check :: IO () -> IO ()
    check action = do
      result <- try action :: IO (Either SomeException ())
      case result of
        Left exception | "Implement generator for" \`isInfixOf\` show exception -> pure ()
        _ -> error "unimplemented factory must fail explicitly"
`);
  run([...packageArgs,'--make',...includes,'-outputdir','build','Main.hs','-o','check']);
  execFileSync(path.join(directory,'check'),[],{cwd:directory,encoding:'utf8'});
  await put('Wrong.hs','module Wrong where\nimport Hedgehog (Gen)\nimport qualified Application.Factories as F\nwrong :: Gen String\nwrong = F.nativeInt8\n');
  const wrong=spawnSync(ghc,[...packageArgs,'--make','-fno-code',...includes,'-outputdir','wrong-build','Wrong.hs'],
    {cwd:directory,encoding:'utf8'});
  assert.notEqual(wrong.status,0);
  assert.match(wrong.stdout+wrong.stderr,/Couldn't match type/);
  console.log(`Haskell ${machineBits}, minify=${minify}: all signatures compile, wrong types rejected, stubs fail explicitly`);
}
