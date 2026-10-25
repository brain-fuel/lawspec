import assert from 'node:assert/strict';
import {test} from 'node:test';
import {recordNativeAttempts} from '../native-evidence.mjs';
import {readNativeObservations,nativeEvidenceText} from '../native-evidence.mjs';
import {mkdtemp,mkdir,readFile,writeFile,rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {projectKey} from '../failure-database.mjs';

const model=(id,name)=>({law:id,key:'plan:'+id,unit:'bank',file:'bank-test',name,label:name,
  obligations:[{declaration:'bank::model::account',stage:'model'}]});
const first=model('sequential','combined_account'),second=model('parallel','combined_account');
const supervisor=model('supervision','supervision');
function run(entries){return {laws:entries,command:'native-runner',matches:test=>entries.filter(entry=>entry.name===test.name)};}
const keys=new Map([first,second,supervisor].map(entry=>[entry.law,'key:'+entry.law]));
const settings={keys,seed:811,profile:{target:'java',root:'/bank',machineBits:64,minify:false},at:'2026-10-17T20:00:00Z'};

test('historical discrepancy observations use the current vocabulary without rewriting or promoting the receipt',async()=>{
  const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-old-observation-'));
  try{
    const entry={law:'bank::law::balance',key:'old-plan',unit:'bank',file:'bank-test',name:'balance',label:'balance'};
    const targets=[{language:'javascript',root:'.'}];
    const file=path.join(root,'.lawspec/results','javascript-'+projectKey(root)+'.json');
    await mkdir(path.dirname(file),{recursive:true});
    for(const selected of [true,false])for(const outcome of ['known-failing','known-discrepancy','failed','passed']){
      const attempt=recordNativeAttempts({laws:[entry],command:'native-runner',matches:()=>[entry]},
        [{name:'balance',status:'passed'}],{...settings,keys:new Map([[entry.law,'old-key']]),ok:true,
          profile:{target:'javascript',root,machineBits:64,minify:false,build:'old-build'}})[entry.law];
      attempt.outcome=outcome;
      const original=JSON.stringify({attempts:{[entry.law]:attempt}});
      await writeFile(file,original);
      const observations=await readNativeObservations({
        compiler:{planGeneration:async()=>({diagnostics:[],tests:selected?[entry]:[],files:[]})},
        input:{machineBits:64},selected:targets,roots:[root],configRoot:root,build:'current-build',evidence:[]});
      assert.equal(observations.length,1);
      const row=observations[0];
      assert.equal(row.outcome,outcome==='known-failing'?'known-discrepancy':outcome);
      assert.equal(row.freshness,selected?'stale':'not-selected');
      assert.deepEqual(row.attempt,JSON.parse(original).attempts[entry.law]);
      assert.equal(await readFile(file,'utf8'),original);
      const [view]=attachNativeEvidence([{declaration:entry.law,stage:'law',status:'planned',reason:'awaiting execution'}],observations);
      assert.equal(view.status,'planned');
      assert.equal(view.nativeEvidence.searchCompleteness,'not-established');
      assert.doesNotMatch(nativeEvidenceText(view),/known-failing/);
    }
  }finally{await rm(root,{recursive:true,force:true});}
});

test('a failed combined native model method cannot establish either included check',()=>{
  const rows=recordNativeAttempts(run([first,second,supervisor]),[
    {name:'combined_account',status:'failed',reason:'returned 1; model expected 2'},
    {name:'supervision',status:'passed'}],{...settings,ok:false});
  assert.equal(rows.sequential.outcome,'failed');assert.equal(rows.parallel.outcome,'failed');
  assert.equal(rows.supervision.outcome,'passed');
  assert.equal(rows.sequential.tests[0].reason,'returned 1; model expected 2');
  for(const row of Object.values(rows)){
    assert.equal(row.searchCompleteness,'not-established');assert.equal(row.verification,'native-execution');
    assert.equal(row.seed,811);
  }
});

test('native zero-discovery, skipped cases and failed setup cannot become successful evidence',()=>{
  assert.equal(recordNativeAttempts(run([first]),[],{...settings,ok:true}).sequential.outcome,'incomplete');
  assert.equal(recordNativeAttempts(run([first]),[{name:first.name,status:'skipped'}],{...settings,ok:true}).sequential.outcome,'skipped');
  const law={...first,law:'requirement',obligations:undefined};
  assert.equal(recordNativeAttempts(run([law]),[{name:first.name,status:'passed'}],{...settings,ok:false}).requirement.outcome,'incomplete');
});

test('an explicitly incomplete native result stays incomplete even when its process succeeds',()=>{
  const rows=recordNativeAttempts(run([first]),[{name:first.name,status:'incomplete',
    failure:'the search bound was exhausted'}],{...settings,ok:true});
  assert.equal(rows.sequential.outcome,'incomplete');
  assert.equal(rows.sequential.tests[0].status,'incomplete');
  assert.equal(rows.sequential.searchCompleteness,'not-established');
});

import {attachNativeEvidence,attestedKeys} from '../native-evidence.mjs';
const obligation={owner:'bank',declaration:'bank::model::account',stage:'model',status:'planned',
  reason:'native model checks are planned',claim:null};
const observation=(target,outcome='passed',freshness='matching-inputs')=>({target,root:'/'+target,
  check:{id:target,obligations:[{declaration:obligation.declaration,stage:obligation.stage}]},
  outcome,freshness,reason:'native completion',coverage:{kind:'sampled',scopedQuantifiers:false}});

test('native evidence preserves scope, stale results, failures and unselected obligations',()=>{
  const apply=rows=>attachNativeEvidence([obligation],rows)[0];
  const complete=apply([observation('python'),observation('java')]);
  assert.equal(complete.status,'property-tested');assert.equal(complete.claim,obligation.claim);
  assert.equal(complete.nativeEvidence.status,'passed');assert.equal(complete.nativeEvidence.searchCompleteness,'not-established');
  assert.equal(apply([observation('python','passed','stale')]).status,'planned');
  assert.equal(apply([observation('python'),observation('java','not-run','not-run')]).nativeEvidence.status,'partial');
  assert.equal(apply([observation('python'),observation('java','failed')]).status,'incomplete');
  const unselected=attachNativeEvidence([{...obligation,status:'not-verified'}],[observation('python','passed','not-selected')])[0];
  assert.equal(unselected.status,'not-verified');assert.equal(unselected.nativeEvidence.status,'not-selected');
  const proved=attachNativeEvidence([{...obligation,status:'proved'}],[observation('python','failed')])[0];
  assert.equal(proved.status,'proved');assert.equal(proved.nativeEvidence.status,'failed');
});

test('complete finite inputs remain distinct from nested witness or universal search',()=>{
  const row={...observation('python'),coverage:{kind:'finite-inputs',cases:2,scopedQuantifiers:false}};
  assert.equal(attachNativeEvidence([obligation],[row])[0].status,'exhaustively-checked');
  row.coverage.scopedQuantifiers=true;
  const scoped=attachNativeEvidence([obligation],[row])[0];
  assert.equal(scoped.status,'property-tested');assert.equal(scoped.nativeEvidence.searchCompleteness,'not-established');
});

test('attestation cache keys include planned wiring and change with the declared endpoint',()=>{
  const result=endpoint=>({evidence:[{declaration:'charge',plannedEnvironment:'staging',plannedAgainst:[{endpoint}]}]});
  assert.notEqual(attestedKeys(result('one')).get('charge'),attestedKeys(result('two')).get('charge'));
});

test('attestation cache keys are wiring only: what the run observed changes none',()=>{
  const gateway={dependency:'Gateway',endpoint:'localhost:9092',reached:true,kind:'stand-in',provider:'fixture',
    standIn:{identity:'acme/gateway',version:'0.1.0',conformance:'3',historyDigest:'sha256:'+'a'.repeat(64)}};
  const key=(d,linked=false)=>attestedKeys({evidence:[linked
    ?{declaration:'charge',environment:'staging',against:[d],environmentOutcome:'passed'}
    :{declaration:'charge',plannedEnvironment:'staging',plannedAgainst:[d]}]}).get('charge');
  const base=key(gateway);
  assert.equal(key({...gateway,reached:false,standIn:{...gateway.standIn,historyDigest:'sha256:'+'b'.repeat(64)},
    completed:{reached:true,historyDigest:'sha256:'+'c'.repeat(64)},ranAgainst:{provider:'fixture'},node:'gateway'}),base);
  assert.equal(key(gateway,true),base);
  assert.notEqual(key({...gateway,standIn:{...gateway.standIn,conformance:'2'}}),base);
  assert.notEqual(key({...gateway,kind:'real',standIn:undefined}),base);
});

test('native failure output remains available when a framework has no per-case failure payload',()=>{
  const rows=recordNativeAttempts(run([first]),[{name:first.name,status:'failed'}],{
    ...settings,ok:false,output:'model account: actual 1, expected 2; shrunk input deposit(1)'});
  assert.match(rows.sequential.invocation.output,/actual 1, expected 2/);
});

import {nativeSeed} from '../native-evidence.mjs';
test('native seeds retain exact large integer tokens for replay and reject already rounded records',()=>{
  assert.equal(nativeSeed('811'),811);assert.equal(nativeSeed('0'),0);
  assert.equal(nativeSeed('9007199254740993'),'9007199254740993');
  assert.equal(nativeSeed('123456789012345678901234567890'),'123456789012345678901234567890');
  assert.throws(()=>nativeSeed(9007199254740992),/lost precision/);
  const rows=recordNativeAttempts(run([first]),[{name:first.name,status:'passed'}],{
    ...settings,ok:true,seed:'9007199254740993'});
  assert.equal(rows.sequential.seed,'9007199254740993');
});

test('a failed combined native method leaves each logical obligation incomplete, not individually refuted',()=>{
  const attempts=recordNativeAttempts(run([first,second]),[{name:first.name,status:'failed'}],{...settings,ok:false});
  assert.deepEqual(attempts.sequential.check.nativeGroup,[first.law,second.law]);
  const row={...observation('java','failed'),attempt:attempts.sequential};
  const result=attachNativeEvidence([obligation],[row])[0];
  assert.equal(result.status,'incomplete');assert.equal(result.nativeEvidence.status,'incomplete');
  assert.match(result.reason,/specific included logical check is not identified/);
});

test('current native evidence retains retry and adequacy observations without promoting stale runs',()=>{
  const adequacy=[{test:'generated',cases:20,cover:[{label:'credit',observed:50,required:40,met:true}]}];
  const row={...observation('python'),harness:{flaky:true,adequacy}};
  const result=attachNativeEvidence([obligation],[row])[0];
  assert.equal(result.status,'flaky');assert.deepEqual(result.adequacy,adequacy);
  assert.match(result.reason,/failed, then passed on a retry/);
  const stale=attachNativeEvidence([obligation],[{...row,freshness:'stale'}])[0];
  assert.equal(stale.status,'planned');assert.equal(stale.adequacy,undefined);
  assert.equal(attachNativeEvidence([{...obligation,status:'proved'}],[row])[0].status,'proved');
});


test('real-provider implementation changes invalidate wiring keys without inventing a fresh run',()=>{
  const dependency={dependency:'Gateway',endpoint:'localhost:8080',kind:'real',provider:'real',
    implementation:{kind:'application',product:'gateway',version:'1.0.0',commit:'first'}};
  const key=value=>attestedKeys({evidence:[{declaration:'charge',plannedEnvironment:'staging',plannedAgainst:[value]}]}).get('charge');
  assert.notEqual(key(dependency),key({...dependency,implementation:{...dependency.implementation,commit:'second'}}));
  assert.notEqual(key(dependency),key({...dependency,implementation:{...dependency.implementation,version:'1.0.1'}}));
  assert.equal(key(dependency),key({...dependency,reached:true,historyDigest:'observed',completed:{reached:true}}));
});
