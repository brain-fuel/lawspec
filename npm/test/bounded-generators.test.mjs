// Generated from templates/npm/test/bounded-generators.test.mjs by lawspec-dev generate. Do not edit.
import {semanticFacts} from './compiler-input.mjs';
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';
import {targets} from '../templates.mjs';

test('bounded generation retains typed meaning and intrinsic checking through the public API',async()=>{
  const compiler=await createCompiler();
  const content=await readFile(new URL('../../test/fixtures/canonical-bounded-generators.lawspec',import.meta.url),'utf8');
  const sources=[{path:'canonical-bounded-generators.lawspec',content}];
  for(const machineBits of [32,64]){
    const input={schemaVersion:5,languageProfile:'1.0-rc.2',machineBits,
      verification:{layers:['property','examples']},sources};
    const before=await compiler.check({...input});
    assert.deepEqual(before.diagnostics,[]);assert.equal(before.laws.length,6);
    const formatted=await compiler.format(input);assert.deepEqual(formatted.diagnostics,[]);
    const after=await compiler.check({...input,sources:formatted.formattedSources});
    assert.deepEqual(after.diagnostics,[]);
    assert.deepEqual(semanticFacts(after),semanticFacts(before));
    const twice=await compiler.format({...input,sources:formatted.formattedSources});
    assert.deepEqual(twice.formattedSources,formatted.formattedSources);
    for(const target of targets){
      const result=await compiler.planGeneration({...input,target,minify:machineBits===32});
      assert.deepEqual(result.diagnostics,[],`${target}/${machineBits}`);
      assert.ok(result.files.length>0);
    }
    const none=await compiler.check({...input,verification:{layers:[]}});
    assert.deepEqual(none.diagnostics,[]);
    assert.equal(none.verification.selection,'no-selected-checks');
    const lawEvidence=none.evidence.filter(item=>item.stage==='law');
    assert.equal(lawEvidence.length,6);
    assert.ok(lawEvidence.every(item=>item.status==='not-verified'));
    const invalid=await compiler.check({...input,verification:{layers:[]},sources:[{path:'invalid.lawspec',
      content:`unit invalid

function unsafe (value :: Int64) -> Integer is prelude.quot value 0 end function

end unit
`}]});
    assert.ok(invalid.diagnostics.some(item=>item.code==='total'),
      'No selected law checks cannot disable definedness');
  }
});
