import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mkdtemp,readFile,rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createCompiler} from '../api.mjs';
import {programTargets} from '../templates.mjs';
import {recordNativeAttempts,attachNativeEvidence} from '../native-evidence.mjs';

const reason='Review the specification and implementation together';
const content=`unit mismatch
value :: Int32 -> Int32
law agrees is
  definition: for all (x :: Int32) => value x must be x end for all end definition
end law
harness review for mismatch is
  known discrepancy "${reason}"
end harness
end unit
`;
const input={languageProfile:'1.0-rc.2',verification:{layers:['property']},
  sources:[{path:'mismatch.lawspec',content}]};

test('known discrepancies have a reason and no assignment of fault in evidence and every target manifest',async()=>{
  const compiler=await createCompiler();
  const checked=await compiler.check(input);
  assert.deepEqual(checked.diagnostics,[]);
  const row=checked.evidence.find(row=>row.stage==='law');
  assert.equal(row.status,'known-discrepancy');
  assert.match(row.reason,/specification.*implementation|implementation.*specification/);
  assert.ok(row.reason.includes(reason));
  for(const target of programTargets){
    const plan=await compiler.planGeneration({...input,target});
    assert.deepEqual(plan.diagnostics,[],target);
    assert.equal(plan.tests.length,1,target);
    assert.equal(plan.tests[0].knownDiscrepancy,reason,target);
    assert.equal('knownDiscrepancy' in plan.tests[0],false,target);
  }
});

test('a known discrepancy cannot override a compiler proof or mandatory definition validation',async()=>{
  const compiler=await createCompiler();
  const proved=content.replace('value x must be x','x must be x');
  const result=await compiler.check({...input,verification:{layers:['proof']},
    sources:[{path:'proved.lawspec',content:proved}]});
  assert.ok(result.diagnostics.some(d=>d.code==='harness'&&/known discrepancy/.test(d.message)));
  const invalid=await compiler.check({...input,verification:{layers:[]},
    sources:[{path:'invalid.lawspec',content:content.replace('value :: Int32 -> Int32',
      'value :: Int32 -> Int32\nfunction broken (x :: Rational) -> Rational is x / 0 end function')}]});
  assert.ok(invalid.diagnostics.some(d=>/zero|defined|division/i.test(d.message)));
  assert.ok(invalid.diagnostics.every(d=>d.code!=='parse'));
});

test('triple-quoted discrepancy reasons preserve their content through formatting and native plans',async()=>{
  const compiler=await createCompiler();
  const multiline='Review "the specification"\nand the implementation together.\n  Either or both may need correction.  ';
  const source=content.replace(`"${reason}"`,'"""'+multiline+'"""');
  const request={...input,sources:[{path:'mismatch.lawspec',content:source}]};
  const checked=await compiler.check(request);
  assert.deepEqual(checked.diagnostics,[]);
  assert.ok(checked.evidence.find(row=>row.stage==='law').reason.includes(multiline));
  const formatted=await compiler.format(request);
  assert.deepEqual(formatted.diagnostics,[]);
  const again=await compiler.format({...request,sources:formatted.formattedSources});
  assert.deepEqual(again.formattedSources,formatted.formattedSources);
  for(const target of programTargets){
    const plan=await compiler.planGeneration({...request,sources:formatted.formattedSources,target});
    assert.deepEqual(plan.diagnostics,[],target);
    assert.equal(plan.tests[0].knownDiscrepancy,multiline,target);
  }
});

test('the native harness reports a reproduced discrepancy and requires review when it disappears',async()=>{
  const {knownDiscrepancy,HarnessError}=await import('../../runtime/lawspec_harness.mjs');
  const directory=await mkdtemp(path.join(os.tmpdir(),'lawspec-discrepancy-'));
  const previous=process.env.LAWSPEC_STATS;
  process.env.LAWSPEC_STATS=directory;
  try{
    await knownDiscrepancy('mismatch::agrees','reproduced',reason,[()=>{throw new Error('actual 2, expected 1');}]);
    const observed=JSON.parse(await readFile(path.join(directory,'reproduced.json'),'utf8'));
    assert.deepEqual(observed,{law:'mismatch::agrees',test:'reproduced',outcome:'known-discrepancy',reason});
    await assert.rejects(knownDiscrepancy('mismatch::agrees','resolved',reason,[()=>{}]),
      error=>error instanceof HarnessError&&/review.*specification.*implementation/.test(error.message));
    assert.equal(JSON.parse(await readFile(path.join(directory,'resolved.json'),'utf8')).outcome,
      'known-discrepancy-passed');
  }finally{
    if(previous===undefined)delete process.env.LAWSPEC_STATS;else process.env.LAWSPEC_STATS=previous;
    await rm(directory,{recursive:true,force:true});
  }
});

test('native discrepancy observations retain their status without becoming a passing proof',()=>{
  const entry={law:'mismatch::agrees',unit:'mismatch',key:'plan',file:'tests',name:'agrees',
    knownDiscrepancy:reason};
  const run={laws:[entry],command:'runner',matches:()=>[entry]};
  const attempts=recordNativeAttempts(run,[{name:'agrees',status:'passed'}],{
    keys:new Map([[entry.law,'key']]),seed:1,ok:true,profile:{target:'javascript'}});
  assert.equal(attempts[entry.law].outcome,'known-discrepancy');
  const [evidence]=attachNativeEvidence([{declaration:entry.law,stage:'law',status:'known-discrepancy',reason}],
    [{target:'javascript',root:'/project',outcome:'known-discrepancy',freshness:'matching-inputs',
      check:{id:entry.law,obligations:[{declaration:entry.law,stage:'law'}]}}]);
  assert.equal(evidence.status,'known-discrepancy');
  assert.equal(evidence.nativeEvidence.status,'known-discrepancy');
  assert.equal(evidence.nativeEvidence.searchCompleteness,'not-established');
});
