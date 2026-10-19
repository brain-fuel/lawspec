// Generated from templates/npm/test/branch-admission.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';
import {explainLaw} from '../explain.mjs';

const compiler=await createCompiler();
const content=await readFile(new URL('../../test/fixtures/canonical-branch-admission.lawspec',import.meta.url),'utf8');
const sources=[{path:'admission.lawspec',content}];
const options={schemaVersion:5,languageProfile:'1.0-rc.2',verification:{layers:['exhaustive','examples']}};
const targets=['java','python','javascript','typescript','go','haskell','kotlin','rust','erlang','elixir','gleam','fsharp','csharp','scala','groovy','clojure','swift'];
const privateNames=/selection-row:|selection-branch-check:|_lawspecUnreachableBranchResult_/;

test('discarded row admission retains ordered outcomes and native generation across targets, widths and layouts',async()=>{
  for(const machineBits of [32,64]) {
    const result=await compiler.check({...options,machineBits,sources});
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.laws.length,4);
    assert.equal(result.laws.reduce((count,law)=>count+law.examples.length,0),4);
    const laws=result.evidence.filter(row=>row.stage==='law');
    assert.equal(laws.length,4);
    assert.ok(laws.every(row=>row.status==='exhaustively-checked'));
    assert.doesNotMatch(JSON.stringify(result),privateNames);
    for(const target of targets)for(const minify of [false,true]) {
      const generated=await compiler.planGeneration({...options,machineBits,sources,target,minify});
      assert.deepEqual(generated.diagnostics,[],target+' '+machineBits+' '+minify);
      assert.ok(generated.files.length>0);
    }
  }
});

test('discarded bodies, guards and fallbacks remain typed without optional law verification',async()=>{
  const selected=(result,rows)=>`function selected (value of type Bool) -> ${result} is first matching case of value: ${rows} end case end function`;
  const invalid=[
    selected('Bool','when #any then true when true then absent'),
    selected('Bool','when #any then true when true then 7'),
    selected('Bool','when #any then true when true if 7 then false'),
    selected('Bool','when true then true when false then false otherwise absent'),
    selected('Bool','when it matches bound then bound otherwise bound'),
    selected('UInt8','when #any then 0 when true then 256'),
    `function selected (value of type a) -> Bool is first matching case of value: when #any then true when it matches bound if bound = bound then true end case end function
`,
    `type Value (a of type Type) is one of | Number of type Integer where a = Integer | Truth of type Bool where a = Bool end type
function read (value of type Value a) -> a is first matching case of value: when Number n then n when Truth b then b when Number n then false end case end function
`,
    `procedure selected (value of type Bool) -> Bool is first matching case of value: when #any then true when true if 7 then false end case end procedure
`,
    `law requirement is definition: for all (value of type Bool) => first matching case of value: when #any then true when true then absent end case end for all end definition end law
`,
  ];
  for(const machineBits of [32,64])for(const body of invalid)for(const method of ['check','expand']) {
    const result=await compiler[method]({...options,verification:{layers:[]},machineBits,
      sources:[{path:'invalid.lawspec',content:'unit invalid\n'+body}]});
    assert.ok(result.diagnostics.length>0,body);
    assert.ok(result.diagnostics.every(row=>row.code!=='parse'),JSON.stringify(result.diagnostics));
  }
});

test('formatting and explanation preserve valid source and obligations without leaking admission locals',async()=>{
  const result=await compiler.check({...options,sources});
  assert.deepEqual(result.diagnostics,[]);
  const unselected=await compiler.check({...options,verification:{layers:[]},sources});
  assert.deepEqual(unselected.diagnostics,[]);
  const laws=unselected.evidence.filter(row=>row.stage==='law');
  assert.equal(laws.length,4);
  assert.ok(laws.every(row=>row.status==='not-verified'));
  const formatted=await compiler.format({...options,sources});
  assert.deepEqual(formatted.diagnostics,[]);
  assert.deepEqual((await compiler.format({...options,sources:formatted.formattedSources})).formattedSources,formatted.formattedSources);
  const repeated=await compiler.check({...options,sources:formatted.formattedSources});
  assert.deepEqual(repeated.diagnostics,[]);
  assert.deepEqual(repeated.dataTypes.map(row=>row.id),result.dataTypes.map(row=>row.id));
  const before=structuredClone(result);
  for(const law of result.laws)for(const view of ['developer','business','formal','evidence']) {
    const explanation=explainLaw(law,result,view);
    assert.equal(explanation.assertion,law.assertion);
    assert.deepEqual(explanation.evidence,result.evidence.filter(row=>row.declaration===law.id));
    assert.doesNotMatch(explanation.text,privateNames);
  }
  assert.deepEqual(result,before);
});
