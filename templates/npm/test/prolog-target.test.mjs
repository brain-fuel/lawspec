import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
import {createCompiler} from '../api.mjs';
import {programTargets,artifactTargets} from '../templates.mjs';

const compiler=await createCompiler();
const fixture=async name=>({path:name+'.lawspec',content:await readFile(
  new URL('../../test/fixtures/prolog/'+name+'.lawspec',import.meta.url),'utf8')});
const input={schemaVersion:5,languageProfile:'1.0-rc.2',target:'prolog',
  verification:{layers:['exhaustive','property','examples','runtime','model']}};

test('Prolog public dispatch preserves law and exact model slots at both widths and layouts',async()=>{
  assert.ok(programTargets.includes('prolog'));assert.ok(!artifactTargets.includes('prolog'));
  const sources=await Promise.all(['basic','effects','async-model'].map(fixture));
  for(const machineBits of [32,64])for(const minify of [false,true]){
    const result=await compiler.planGeneration({...input,sources,machineBits,minify,
      sourceDir:'app/code',testDir:'checks/generated'});
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.tests.length,13);
    assert.equal(result.tests.filter(entry=>entry.kind==='model').length,3);
    assert.ok(result.tests.every(entry=>entry.file.startsWith('checks/generated/')&&entry.file.endsWith('.pl')));
    assert.ok(result.files.some(file=>file.path==='app/code/lawspec_models/example/prologBasic.pl'));
    const metadata=JSON.parse(result.files.find(file=>file.path==='lawspec-prolog-tests.json').content);
    assert.equal(metadata.length,13);
    for(const entry of result.tests){
      const slot=metadata.find(slot=>slot.file===entry.file&&slot.name===entry.name);
      assert.ok(slot);assert.equal(slot.exact,entry.kind==='model');
      assert.ok(slot.hostFile.startsWith('checks/generated/')&&slot.hostFile.endsWith('.py'));
    }
  }
});

test('Prolog binds native functions and production handlers without source scraping',async()=>{
  const result=await compiler.planGeneration({...input,sources:[await fixture('effects')],
    nativeBindings:{functions:[{declaration:'example.prologEffects::execute',native:['application','run']}],
      handlers:[{ability:'example.prologEffects::Ledger',native:['application','ledger']}]}});
  assert.deepEqual(result.diagnostics,[]);
  const host=result.files.find(file=>file.path==='src/example/prologEffects.py').content;
  assert.match(host,/application\.pl/);assert.match(host,/ledger_add/);
  const stub=result.files.find(file=>file.path==='src/example/prologEffects.pl').content;
  assert.ok(!stub.includes("'ls_execute'/"));assert.ok(!stub.includes('handler_LedgerHandler_new'));
});

test('Prolog generic generator scaffolds preserve child strategies and output ownership',async()=>{
  const sources=[{path:'box.lawspec',content:`unit box
type Box (a :: Type) is a record{value :: a} end type
law identity is definition: for all (x :: Box UInt8) => x must be x end for all end definition end law
end unit`}];
  const result=await compiler.planGeneration({...input,sources,sourceDir:'app/code',testDir:'checks/generated',
    nativeBindings:{generators:[{type:'box::type::Box',factory:['native','boxes','make'],stub:true}]}});
  assert.deepEqual(result.diagnostics,[]);
  const stub=result.files.find(file=>file.path==='checks/generated/native/boxes.pl');
  assert.equal(stub.ownership,'user');assert.match(stub.content,/'make'\/2/);
  const helper=result.files.find(file=>file.path==='checks/generated/lawspec_prolog_generators.py');
  assert.equal(helper.ownership,'generated');assert.match(helper.content,/def factory_0\(child0\)/);
  assert.match(helper.content,/bridge\.generator_factory/);
  assert.ok(!result.files.some(file=>file.ownership==='user'&&file.path.endsWith('.py')));
});

test('Prolog requires a native handle type for constructor bindings and always validates definitions',async()=>{
  const sources=[{path:'native.lawspec',content:'unit native\nhandle Counter\nnewCounter :: Unit -> Counter\nend unit'}];
  const result=await compiler.planGeneration({...input,sources,
    nativeBindings:{functions:[{declaration:'native::newCounter',constructor:['application','counter']}]}});
  assert.ok(result.diagnostics.some(diagnostic=>diagnostic.code==='native-binding'));
  assert.deepEqual(result.files??[],[]);
  const invalid=await compiler.planGeneration({...input,verification:{layers:[]},sources:[{
    path:'invalid.lawspec',content:'unit invalid\nfunction bad (u :: Unit) -> UInt8 is 300 end function\nend unit'}]});
  assert.ok(invalid.diagnostics.some(diagnostic=>['definition','total'].includes(diagnostic.code)));
  assert.deepEqual(invalid.files??[],[]);
});

test('Prolog admits native record, handler, failure, constructor and method bindings through the public API',async()=>{
  const sources=[{path:'interop.lawspec',content:`unit interop
type Money is a record{cents :: Int64} end type
type Refusal is one of | Blocked of type record{message :: Text} end type
handle Shelf
ability Drawer is
 take :: Money -> Money
end ability
pay :: Int64 -> Money uses Drawer fails with Refusal
newShelf :: Unit -> Shelf
async fill :: Shelf -> UInt8 -> Unit
end unit`}];
  const nativeBindings={
    types:[{type:'interop::type::Money',native:['native','Cash'],constructors:[{
      constructor:'Money',native:['native','Cash'],style:'record',fields:[{field:'cents',native:'amount'}]}]},
      {type:'interop::type::Shelf',native:['native','Shelf']}],
    functions:[{declaration:'interop::pay',native:['native','pay']},
      {declaration:'interop::newShelf',constructor:['native','Shelf']},
      {declaration:'interop::fill',method:'fill'}],
    handlers:[{ability:'interop::Drawer',native:['native','Till']}],
    failures:[{native:['native','Declined'],failure:'interop::Refusal::Blocked'}]};
  for(const machineBits of [32,64])for(const minify of [false,true]){
    const result=await compiler.planGeneration({...input,sources,nativeBindings,machineBits,minify});
    assert.deepEqual(result.diagnostics,[]);
    assert.ok(result.files.some(file=>file.path==='src/lawspec_prolog_models.py'));
    assert.ok(!result.files.some(file=>file.path==='src/interop.pl'&&file.ownership==='user'));
  }
});

test('Prolog retains examples and exhaustive slots independently of property and model selection',async()=>{
  const sources=[{path:'selection.lawspec',content:`unit selection
echo :: Bool -> Bool
law echoes is
  definition: for all (x :: Bool) => echo x must be x end for all end definition
  example known: x = true expect echo x = true end example
end law
end unit`}];
  for(const layers of [[],['examples'],['exhaustive'],['property'],['model']]){
    const result=await compiler.planGeneration({...input,sources,verification:{layers}});
    assert.deepEqual(result.diagnostics,[]);
    const slots=JSON.parse(result.files.find(file=>file.path==='lawspec-prolog-tests.json').content);
    const expected=layers.some(layer=>['examples','exhaustive','property'].includes(layer))?1:0;
    assert.equal(result.tests.length,expected,JSON.stringify(layers));
    assert.equal(slots.length,expected,JSON.stringify(layers));
    if(expected)assert.equal(slots[0].name,result.tests[0].name);
  }
});

// A domain proof is retained without inventing an observed native case.
// ref:REQ-test-manifest
test('Prolog omits a complete empty-domain native slot while retaining its Core evidence',async()=>{
  const sources=[{path:'empty.lawspec',content:`unit emptyManifest
law vacuous is definition: for all (x :: Integer) (y :: Integer where y > x and y < x + 1) => false end for all end definition end law
law ordinary is definition: for all (x :: Integer) => x must be x end for all end definition end law
end unit`}];
  for(const machineBits of [32,64])for(const minify of [false,true]){
    const result=await compiler.planGeneration({...input,sources,machineBits,minify,
      verification:{layers:['proof','exhaustive','property','examples']}});
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.laws.length,2);
    assert.deepEqual(result.tests.map(entry=>entry.law),['emptyManifest::law::ordinary']);
    const evidence=result.evidence.find(item=>item.declaration==='emptyManifest::law::vacuous'&&item.stage==='law');
    assert.ok(['proved','exhaustively-checked'].includes(evidence.status));
    const slots=JSON.parse(result.files.find(file=>file.path==='lawspec-prolog-tests.json').content);
    assert.equal(slots.length,1);assert.equal(slots[0].name,result.tests[0].name);
  }
});
