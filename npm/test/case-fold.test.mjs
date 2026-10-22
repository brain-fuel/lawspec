// Generated from templates/npm/test/case-fold.test.mjs by lawspec-dev generate. Do not edit.
import {semanticFacts} from './compiler-input.mjs';
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';
import {explainLaw} from '../explain.mjs';
import {programTargets as targets} from '../templates.mjs';

test('pinned full Unicode folding preserves author names, scope and mandatory checks through the WASM API',async()=>{
  const compiler=await createCompiler();
  const sources=[{path:'folding.lawspec',content:`unit folding

function caseFold (text of type Text) -> Text is text end function
function folded (text of type Text) -> Text is prelude.caseFold text end function
law local is definition: caseFold "A" must be "A" end definition end law
law portable is definition: prelude.caseFold "Straße Σς ﬃ İ I 𐐀" must be "strasse σσ ffi i̇ i 𐐨" end definition end law
law substring is definition: prelude.any (prelude.textContains "xSHITx") ["SHIT"] end definition end law

end unit
`}];
  for(const machineBits of [32,64]){
    const input={schemaVersion:5,languageProfile:'1.0-rc.2',machineBits,verification:{layers:['exhaustive']},sources};
    const result=await compiler.check(input);
    assert.deepEqual(result.diagnostics,[]);
    assert.ok(result.evidence.filter(item=>item.stage==='law').every(item=>item.status==='exhaustively-checked'));
    const law=result.laws.find(law=>law.name==='portable');assert.ok(law);
    const business=explainLaw(law,result,'business');
    assert.match(business.text,/prelude\.caseFold/);
    assert.doesNotMatch(business.text,/textFoldPoint|lawspecTextTextCaseFold/);
    const none=await compiler.check({...input,verification:{layers:[]}});
    assert.deepEqual(none.diagnostics,[]);
    assert.ok(none.evidence.filter(item=>item.stage==='law').every(item=>item.status==='not-verified'));
    const invalid=await compiler.check({...input,verification:{layers:[]},sources:[{path:'bad.lawspec',
      content:`unit bad

function bad (value :: Integer) -> Text is prelude.caseFold value end function

end unit
`}]});
    assert.ok(invalid.diagnostics.length>0,'Optional layers cannot disable type checking');
    const forbidden=await compiler.check({...input,sources:[{path:'owned.lawspec',content:`unit lawspec.text


end unit
`}]});
    assert.ok(forbidden.diagnostics.some(item=>item.code==='reserved-unit'));
    for(const target of targets){
      const generation=await compiler.planGeneration({...input,target,minify:machineBits===32});
      assert.deepEqual(generation.diagnostics,[],`${target}/${machineBits}`);
      assert.ok(generation.files.length>0);
    }
  }
});

test('the complete upstream mapping corpus and picture examples retain checked behavior through formatting',async()=>{
  const compiler=await createCompiler();
  const paths=['examples/rc1/picture-tuples.lawspec','examples/rc1/picture-records.lawspec',
    'examples/rc1/banner-filenames.lawspec','test/fixtures/canonical-unicode-casefold.lawspec'];
  const sources=await Promise.all(paths.map(async path=>({path,
    content:await readFile(new URL('../../'+path,import.meta.url),'utf8')})));
  const input={schemaVersion:5,languageProfile:'1.0-rc.2',verification:{layers:['property','examples']},sources};
  const before=await compiler.check({...input});assert.deepEqual(before.diagnostics,[]);
  const formatted=await compiler.format(input);assert.deepEqual(formatted.diagnostics,[]);
  const after=await compiler.check({...input,sources:formatted.formattedSources});
  assert.deepEqual(after.diagnostics,[]);

  assert.deepEqual(semanticFacts(after),semanticFacts(before));
  const twice=await compiler.format({...input,sources:formatted.formattedSources});assert.deepEqual(twice.diagnostics,[]);
  assert.deepEqual(twice.formattedSources,formatted.formattedSources);
  const declarations=before.laws.filter(law=>!law.id.startsWith('lawspec.'));
  assert.equal(declarations.length,4);
  assert.equal(declarations.flatMap(law=>law.examples).length,18);
});
