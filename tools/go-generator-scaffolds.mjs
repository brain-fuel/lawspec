// Compile complete Rapid scaffold signatures, including imported model types.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, writeFile, rm} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';
const root=path.resolve(import.meta.dirname,'..');
const compiler=process.env.LAWSPEC_CORE;
assert.ok(compiler,'Set LAWSPEC_CORE');
const wasm=await createCompiler();
const env={...process.env,GOCACHE:path.join(root,'.artifacts/go-cache'),GOTOOLCHAIN:'local',GOPROXY:'off'};
const rapid=process.env.LAWSPEC_RAPID ?? path.join(execFileSync('go',['env','GOMODCACHE'],{encoding:'utf8'}).trim(),'pgregory.net/rapid@v1.2.0');
const scalars=['Bool',...['Int','UInt'].flatMap(prefix=>[8,16,32,64].map(width=>prefix+width)),
  'IntSize','UIntSize','UIntPtr','Integer','BigInt','BigUInt','Decimal','Rational',
  'Float32','Float64','Complex64','Complex128','Char','CodePoint','CodeUnit16',
  'Text','CodePointText','Utf16Text','Bytes','Symbol','Unit','Null','Undefined'];
const types=[...scalars,...['List Int8','Maybe Int8','Either Int8 Text','Nullable Int8','Optional Int8','T0 Int8','Box Int8']];
const generators=types.map(type=>({type:type.startsWith('T0 ')?'catalog::type::T0':
  type.startsWith('Box ')?'catalog::type::Box':type.split(' ')[0],
  factory:[`Native${type.split(' ')[0]}`],stub:true}));
const source='unit catalog\ntype T0 (a :: Type) is T0 value :: a end\ntype Box (a :: Type) is Box value :: a end\n'+
  types.map((type,index)=>`law \`catalog ${index}\` is definition is \`for all\` (x :: ${type}) . true end end`).join('\n');
for(const machineBits of [32,64]) for(const minify of [false,true]) {
  const directory=path.join(root,'.artifacts/go-generator-scaffolds',`${machineBits}-${minify}`);
  await rm(directory,{recursive:true,force:true});
  await mkdir(directory,{recursive:true});
  const prefix='library/native';
  const request={schemaVersion:4,method:'planGeneration',target:'go',machineBits,minify,sourceDir:prefix,testDir:prefix,
    sources:[{path:'catalog.lawspec',content:source}],nativeBindings:{generators,
      goImports:[{alias:'model',path:'fixture/model'}],types:[{type:'catalog::type::Box',native:['model','NativeBox'],
        constructors:[{constructor:'Box',native:['model','NativeBox'],style:'record',fields:[{field:'value',native:'Value'}]}]}]}};
  const result=JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),encoding:'utf8',maxBuffer:64*1024*1024}));
  assert.deepEqual(result.diagnostics,[]);
  assert.deepEqual(await wasm.planGeneration(request),result);
  const put=async(relative,content)=>{
    const file=path.join(directory,relative);
    await mkdir(path.dirname(file),{recursive:true});
    await writeFile(file,content);
  };
  for(const file of result.files) await put(file.path,file.content);
  const stub=result.files.find(file=>file.path.endsWith('/native_generators_test.go'));
  assert.equal(stub.ownership,'user');
  assert.equal(stub.content,execFileSync('gofmt',[],{input:stub.content,encoding:'utf8'}));
  assert.match(stub.content,/NativeT0\[T1 any\]/,'type parameter must not capture canonical T0');
  assert.match(stub.content,/lawSpecImport0.NativeBox\[T1\]/);
  await put('go.mod',`module fixture\n\ngo 1.24.0\nrequire pgregory.net/rapid v1.2.0\nreplace pgregory.net/rapid => ${JSON.stringify(rapid)}\n`);
  await put('model/model.go','package model\ntype NativeBox[T any] struct { Value T }\n');
  await put(`${prefix}/catalog/scaffold_test.go`,`package catalog
import (
  "testing"
  "fixture/model"
  "pgregory.net/rapid"
)
func scaffoldTypes(child *rapid.Generator[int8]) {
  var box *rapid.Generator[model.NativeBox[int8]] = NativeBox(child)
  var canonical *rapid.Generator[T0[int8]] = NativeT0(child)
  var list *rapid.Generator[[]int8] = NativeList(child)
  _, _, _ = box, canonical, list
}
func TestScaffold(t *testing.T) {
  for _, factory := range []func(){
    func() { NativeInt8() }, func() { NativeUnit() }, func() { NativeDecimal() },
    func() { NativeBox(rapid.Int8()) }, func() { NativeNullable(rapid.Int8()) },
    func() { NativeEither(rapid.Int8(), rapid.String()) },
  } {
    func() {
      defer func() { if recover() == nil { t.Fatal("factory must fail until implemented") } }()
      factory()
    }()
  }
}
`);
  execFileSync('go',['build','./...'],{cwd:directory,env,encoding:'utf8'});
  execFileSync('go',['test','./...','-run','^TestScaffold$'],{cwd:directory,env,encoding:'utf8'});
  await put(`${prefix}/catalog/wrong_test.go`,
    'package catalog\nimport "pgregory.net/rapid"\nvar wrong *rapid.Generator[string] = NativeInt8()\n');
  const wrong=spawnSync('go',['test','./...','-run','^$'],{cwd:directory,env,encoding:'utf8'});
  assert.notEqual(wrong.status,0);
  assert.match(wrong.stdout+wrong.stderr,/cannot use/);
  await rm(path.join(directory,prefix,'catalog/wrong_test.go'));
  console.log(`Go ${machineBits}, minify=${minify}: all signatures and imported model compile, wrong types rejected, stubs fail explicitly`);
}
