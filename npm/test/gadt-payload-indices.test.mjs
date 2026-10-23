// Generated from templates/npm/test/gadt-payload-indices.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';
import {explanations,explanationText,explanationViews} from './compiler-input.mjs';

const compiler=await createCompiler();
const path='test/fixtures/canonical-gadt-payload-indices.lawspec';
const content=await readFile(new URL('../../'+path,import.meta.url),'utf8');
const sources=[{path,content}];
const options={schemaVersion:5,languageProfile:'1.0-rc.2',verification:{layers:['exhaustive','examples']}};
const targets=['java','python','javascript','typescript','go','haskell','kotlin','rust','erlang','elixir','gleam','fsharp','csharp','scala','groovy','clojure','swift'];

test('constructor equations determine generic payload fields across targets, widths and layouts',async()=>{
  for(const machineBits of [32,64]) {
    const result=await compiler.check({...options,machineBits,sources});
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.laws.length,4);
    assert.equal(result.laws.reduce((count,law)=>count+law.examples.length,0),10);
    const laws=result.evidence.filter(row=>row.stage==='law');
    assert.equal(laws.length,4);
    assert.ok(laws.every(row=>row.status==='exhaustively-checked'));
    for(const target of targets)for(const minify of [false,true]) {
      const generated=await compiler.planGeneration({...options,machineBits,sources,target,minify});
      assert.deepEqual(generated.diagnostics,[],target+' '+machineBits+' '+minify);
      assert.ok(generated.files.length>0);
    }
  }
});

test('payload indices retain mandatory scalar, branch and result checking without law layers',async()=>{
  const invalid=[
    `type Fixed (a :: Type) is one of | Fixed of type a where a = UInt8 end type
function invalid (ignored :: ()) -> Fixed UInt8 is Fixed true end function
`,
    `type Fixed (a :: Type) is one of | Fixed of type a where a = UInt8 end type
function invalid (ignored :: ()) -> Fixed UInt8 is Fixed 256 end function
`,
    `type Tagged (a :: Type) is one of | Tagged of type a where a = record{value :: UInt8} end type
function invalid (tagged :: Tagged a) -> Bool is first matching case of tagged: when Tagged value then value end case end function
`,
    `type Value (a :: Type) is one of | Number of type a where a = UInt8 | Truth of type a where a = Bool end type
function invalid (value :: Value a) -> UInt8 is first matching case of value: when Number value then value when Truth enabled then enabled.value end case end function
`,
  ];
  for(const machineBits of [32,64])for(const body of invalid)for(const method of ['check','expand']) {
    const result=await compiler[method]({...options,verification:{layers:[]},machineBits,
      sources:[{path:'invalid.lawspec',content:'unit invalid\n'+body+'\nend unit\n'}]});
    assert.ok(result.diagnostics.length>0,body);
    assert.ok(result.diagnostics.every(row=>row.code==='definition'),JSON.stringify(result.diagnostics));
  }
});

test('indexed payload formatting and explanation preserve typed obligations and unselected evidence',async()=>{
  const result=await compiler.check({...options,sources});
  assert.deepEqual(result.diagnostics,[]);
  const unselected=await compiler.check({...options,verification:{layers:[]},sources});
  assert.deepEqual(unselected.diagnostics,[]);
  const laws=unselected.evidence.filter(row=>row.stage==='law');
  assert.equal(laws.length,4);
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
