import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
import {createCompiler} from '../api.mjs';
import {programTargets as targets} from '../templates.mjs';
import {rejectionOutcome,diagnosticText} from '../../templates/site/diagnostic-expectations.mjs';

test('rejection expectations require exactly the named diagnostic and retain readable source context',()=>{
  const diagnostic={code:'total',message:'A nonzero denominator is required.',at:{file:'divide.lawspec',line:4,column:3}};
  assert.equal(rejectionOutcome('total',{diagnostics:[diagnostic]}).matches,true);
  assert.equal(rejectionOutcome('total',{diagnostics:[diagnostic]}).diagnostics[0],diagnostic);
  assert.equal(rejectionOutcome('total',{diagnostics:[{...diagnostic,message:'Revised wording.'}]}).matches,true);
  for(const response of [{diagnostics:[]},{diagnostics:[{...diagnostic,code:'parse'}]},
    {diagnostics:[diagnostic,diagnostic]},{diagnostics:[diagnostic,{code:'parse'}]},
    {diagnostics:[{}]}, {}, null])assert.equal(rejectionOutcome('total',response).matches,false);
  for(const expected of ['',undefined,'total parse','total,parse'])
    assert.equal(rejectionOutcome(expected,{diagnostics:[diagnostic]}).matches,false);
  assert.equal(diagnosticText([diagnostic]),'divide.lawspec:4:3: total: A nonzero denominator is required.');
  assert.match(rejectionOutcome('total',{diagnostics:[]}).message,/specification compiled/);
});

test('authored rejection fixtures fail intrinsically at both widths and every target while corrected sources compile',async()=>{
  const compiler=await createCompiler();
  const fixtures=[['denominator','total',source=>source.replace('value 0','value 1')],
    ['result-type','definition',source=>source.replace('-> Integer','-> Bool')],
    ['address','total',source=>source.replace('32768','32767')]];
  for(const [name,code,repair] of fixtures){
    const file='canonical-rejection-'+name+'.lawspec';
    const content=await readFile(new URL('../../test/fixtures/'+file,import.meta.url),'utf8');
    for(const machineBits of [32,64]){
      const input={schemaVersion:5,languageProfile:'1.0-rc.2',machineBits,
        verification:{layers:[]},sources:[{path:file,content}]};
      const result=await compiler.check(input);
      assert.equal(rejectionOutcome(code,result).matches,true,JSON.stringify(result.diagnostics));
      assert.equal(result.diagnostics[0].at.file,file);
      for(const target of targets){
        const planned=await compiler.planGeneration({...input,target});
        assert.equal(rejectionOutcome(code,planned).matches,true,target+': '+JSON.stringify(planned.diagnostics));
        if ('files' in planned) assert.deepEqual(planned.files,[]);
      }
      const fixed=repair(content);assert.notEqual(fixed,content);
      const accepted=await compiler.check({...input,sources:[{path:file,content:fixed}]});
      assert.deepEqual(accepted.diagnostics,[]);
      assert.equal(accepted.verification.intrinsicDefinitionChecks,true);
      assert.equal(accepted.verification.selection,'no-selected-checks');
      assert.equal(rejectionOutcome(code,accepted).matches,false);
    }
  }
});

test('independent compiler fixtures do not retain declarations from a preceding accepted source',async()=>{
  const compiler=await createCompiler();
  const input={schemaVersion:5,languageProfile:'1.0-rc.2',verification:{layers:[]}};
  const declared=await compiler.check({...input,sources:[{path:'first.lawspec',content:
    `unit example.rejection

function privateValue (value :: Bool) -> Bool is value end function

end unit
`}]});
  assert.deepEqual(declared.diagnostics,[]);
  const independent=await compiler.check({...input,sources:[{path:'second.lawspec',content:
    `unit example.rejection

function second (value :: Bool) -> Bool is privateValue value end function

end unit
`}]});
  assert.equal(independent.diagnostics.length,1);
  assert.match(independent.diagnostics[0].message,/privateValue/);
  assert.equal(independent.diagnostics[0].at.file,'second.lawspec');
});
