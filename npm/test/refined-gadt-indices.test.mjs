// Generated from templates/npm/test/refined-gadt-indices.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';
import {explanations,explanationText,explanationViews} from './compiler-input.mjs';

const compiler=await createCompiler();
const path='test/fixtures/canonical-refined-gadt-indices.lawspec';
const content=await readFile(new URL('../../'+path,import.meta.url),'utf8');
const sources=[{path,content}];
const options={schemaVersion:5,languageProfile:'1.0-rc.2',verification:{layers:['exhaustive','examples']}};
const targets=['java','python','javascript','typescript','go','haskell','kotlin','rust','erlang','elixir','gleam','fsharp','csharp','scala','groovy','clojure','swift'];

test('stored positive and dependent GADT fields justify exact division across targets, widths and layouts',async()=>{
  for(const machineBits of [32,64]) {
    const result=await compiler.check({...options,machineBits,sources});
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.laws.length,5);
    assert.equal(result.laws.reduce((count,law)=>count+law.examples.length,0),12);
    const laws=result.evidence.filter(row=>row.stage==='law');
    assert.equal(laws.length,5);
    assert.ok(laws.every(row=>row.status==='exhaustively-checked'));
    for(const target of targets)for(const minify of [false,true]) {
      const generated=await compiler.planGeneration({...options,machineBits,sources,target,minify});
      assert.deepEqual(generated.diagnostics,[],target+' '+machineBits+' '+minify);
      assert.ok(generated.files.length>0);
    }
  }
});

test('stored field facts preserve mandatory nonzero, construction and branch checks without law layers',async()=>{
  const invalid=[
    `function invalid (reading :: record{value :: UInt8}) -> Rational is 1 / reading.value end function
`,
    `type Reading (a :: Type) is one of | Reading of type a where a = record{value :: (n :: UInt8 where n >= 0)} end type
function invalid (reading :: Reading a) -> Rational is first matching case of reading: when Reading payload then 1 / payload.value end case end function
`,
    `type Reading (a :: Type) is one of | Positive of type a where a = record{value :: (n :: UInt8 where n > 0)} | Open of type a where a = record{value :: UInt8} end type
function invalid (reading :: Reading a) -> Rational is first matching case of reading: when Positive payload then 1 / payload.value when Open payload then 1 / payload.value end case end function
`,
    `type Reading (a :: Type) is one of | Reading of type a where a = record{value :: (n :: UInt8 where n > 0)} end type
function invalid (ignored :: ()) -> Reading record{value :: (n :: UInt8 where n > 0)} is Reading record{value = 0} end function
`,
    `function invalid (span :: record{lower :: UInt8 upper :: (n :: UInt8 where n >= lower)}) -> Rational is 1 / (span.upper - span.lower) end function
`,
    `function supply (value :: Nat) -> record{value :: Nat} is record{value = value} end function
function invalid (ignored :: ()) -> Rational is 1 / (supply 0).value end function
`,
  ];
  for(const machineBits of [32,64])for(const body of invalid)for(const method of ['check','expand']) {
    const result=await compiler[method]({...options,verification:{layers:[]},machineBits,
      sources:[{path:'invalid.lawspec',content:'unit invalid\n'+body+'\nend unit\n'}]});
    assert.ok(result.diagnostics.length>0,body);
    assert.ok(result.diagnostics.every(row=>['definition','total'].includes(row.code)),JSON.stringify(result.diagnostics));
  }
});

test('refined index formatting and explanation preserve typed obligations and unselected evidence',async()=>{
  const result=await compiler.check({...options,sources});
  assert.deepEqual(result.diagnostics,[]);
  const unselected=await compiler.check({...options,verification:{layers:[]},sources});
  assert.deepEqual(unselected.diagnostics,[]);
  const laws=unselected.evidence.filter(row=>row.stage==='law');
  assert.equal(laws.length,5);
  assert.ok(laws.every(row=>row.status==='not-verified'));
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
  }
});
