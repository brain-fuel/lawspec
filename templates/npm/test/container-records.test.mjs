import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';
import {explanations,explanationText,explanationViews} from './compiler-input.mjs';

const compiler=await createCompiler();
const path='test/fixtures/canonical-container-records.lawspec';
const content=await readFile(new URL('../../'+path,import.meta.url),'utf8');
const sources=[{path,content}];
const options={schemaVersion:5,languageProfile:'1.0-rc.2',verification:{layers:['exhaustive','examples']}};
const targets=['java','python','javascript','typescript','go','haskell','kotlin','rust','erlang','elixir','gleam','fsharp','csharp','scala','groovy','clojure','swift'];
const batch='type Batch (a :: Type) is one of | Batch of type List record{value :: a} end type\n';

test('checked recursive structural storage reaches every native target, width and layout',async()=>{
  for(const machineBits of [32,64]) {
    const result=await compiler.check({...options,machineBits,sources});
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.laws.length,7);
    assert.equal(result.laws.reduce((count,law)=>count+law.examples.length,0),5);
    const laws=result.evidence.filter(row=>row.stage==='law');
    assert.equal(laws.filter(row=>row.status==='exhaustively-checked').length,5);
    assert.equal(laws.filter(row=>row.status==='planned').length,2);
    const exhaustiveOnly=await compiler.planGeneration({...options,machineBits,sources,target:'java'});
    assert.ok(exhaustiveOnly.diagnostics.some(row=>row.code==='verification-incomplete'));
    for(const target of targets)for(const minify of [false,true]) {
      const generated=await compiler.planGeneration({...options,verification:{layers:['property','examples']},machineBits,sources,target,minify});
      assert.deepEqual(generated.diagnostics,[],target+' '+machineBits+' '+minify);
      assert.ok(generated.files.length>0);
    }
  }
});

test('container reconstruction preserves mandatory source checks with no selected law layers',async()=>{
  const invalid=[
    batch+'function invalid (items :: List record{other :: Bool}) -> Batch Bool is Batch items end function',
    batch+'type Named is a record{value :: Bool} end type\nfunction invalid (items :: List Named) -> Batch Bool is Batch items end function',
    batch+'function invalid (items :: List record{value :: Bool}) -> Batch Bool is let unused = 1 / 0 in Batch items end let end function',
    batch+'function invalid (batch :: Batch a) -> a is first matching case of batch: when Batch (Cons record{value = item} remaining) then item end case end function',
    batch+'function invalid (batch :: Batch a) -> List record{value :: a} is invalid batch end function',
    `type Stored is a record{items :: List record{value :: Nat}} end type
function invalid (ignored :: ()) -> Stored is Stored record{items = [record{value = 0}]} end function
`,
  ];
  for(const machineBits of [32,64])for(const body of invalid)for(const method of ['check','expand']) {
    const result=await compiler[method]({...options,verification:{layers:[]},machineBits,
      sources:[{path:'invalid.lawspec',content:'unit invalid\n'+body+'\nend unit\n'}]});
    assert.ok(result.diagnostics.length>0,body);
    assert.ok(result.diagnostics.some(row=>['definition','total'].includes(row.code)),JSON.stringify(result.diagnostics));
  }
});

test('container explanations preserve the typed claim and distinguish planned examples from completed evidence',async()=>{
  const result=await compiler.check({...options,sources});
  assert.deepEqual(result.diagnostics,[]);
  const unselected=await compiler.check({...options,verification:{layers:[]},sources});
  assert.deepEqual(unselected.diagnostics,[]);
  assert.equal(unselected.evidence.filter(row=>row.stage==='law').length,7);
  assert.ok(unselected.evidence.filter(row=>row.stage==='law').every(row=>row.status==='not-verified'));
  assert.equal(unselected.verification.intrinsicDefinitionChecks,true);
  const formatted=await compiler.format({...options,sources});
  assert.deepEqual(formatted.diagnostics,[]);
  const repeated=await compiler.format({...options,sources:formatted.formattedSources});
  assert.deepEqual(repeated.formattedSources,formatted.formattedSources);
  const checked=await compiler.check({...options,sources:formatted.formattedSources});
  assert.deepEqual(checked.diagnostics,[]);
  assert.deepEqual(checked.dataTypes.map(row=>row.id),result.dataTypes.map(row=>row.id));
  for(const view of explanationViews)for(const explanation of await explanations(compiler,{...options,sources},view)) {
    assert.ok(result.laws.some(law=>law.id===explanation.law));
    assert.doesNotMatch(explanationText(explanation),/lawspecRecordView/);
  }
});

// Compiler-marked representation calls in presentation: test/ExplainSpec.hs.
