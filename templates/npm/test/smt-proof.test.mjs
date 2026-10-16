import assert from 'node:assert/strict';
import {test} from 'node:test';
import {spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {mkdtemp,writeFile,chmod,rm,symlink} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createCompiler} from '../api.mjs';
import {proveWithZ3,proofTaskFingerprint} from '../proof.mjs';
import {explainLaw} from '../explain.mjs';

const compiler=await createCompiler();
const z3=process.env.LAWSPEC_Z3??(spawnSync('z3',['-version'],{encoding:'utf8'}).status===0?'z3':null);
const requiresZ3={skip:z3?false:'install Z3 or set LAWSPEC_Z3 for real solver integration'};
const localTsc=new URL('../../.integration/typescript/node_modules/.bin/tsc',import.meta.url).pathname;
const tsc=process.env.LAWSPEC_TSC??(existsSync(localTsc)?localTsc:null);
const law=body=>'law selected is definition: '+body+' end end';
const request=(body,layers=['proof'],machineBits=64)=>({schemaVersion:5,languageProfile:'1.0-rc.1',
  verification:{layers},machineBits,sources:[{path:'smt-😀.lawspec',content:'unit smt\n'+body}]});
const square=law('for all (n :: Integer) => n * n >= 0 end');
const falseLaw=law('for all (n :: Integer) => n = n + 1 end');

test('SMT tasks stay separate from completed evidence and preserve mandatory checking with no selected layers',async()=>{
  const planned=await compiler.proofTasks(request(square.replace('law selected','law "|факт😀|')));
  assert.deepEqual(planned.diagnostics,[]);
  assert.equal(planned.proofTasks.length,1);
  assert.equal(planned.proofTasks[0].status,'ready');
  assert.equal(planned.evidence.find(row=>row.stage==='law').status,'planned');
  assert.equal(proofTaskFingerprint(planned.proofTasks[0]),planned.proofTasks[0].taskFingerprint);
  const empty=await proveWithZ3(compiler,request(square,[]),{binary:'/missing/z3'});
  assert.deepEqual(empty.proofTasks,[]);
  assert.deepEqual(empty.solverEvidence,[]);
  assert.ok(empty.evidence.filter(row=>row.stage==='law').every(row=>row.status==='not-verified'));
  const broken=await proveWithZ3(compiler,request('function broken (n :: Integer) -> Rational is 1 / 0 end function',[]),{binary:'/missing/z3'});
  assert.ok(broken.diagnostics.some(row=>row.code==='total'));
  assert.deepEqual(broken.solverEvidence,[]);
});

test('actual Z3 establishes nonlinear and dependent laws from rebuilt-WASM tasks at both widths',requiresZ3,async()=>{
  const samples=[square,
    law('for all (n :: Integer) => there exists (next :: Integer where next > n) such that next = n + 1 end end'),
    law('there does not exist (n :: Integer) such that n * n < 0 end'),
    law('for all (n :: Integer where false) => false end')];
  for(const machineBits of [32,64])for(const body of samples) {
    const input=request(body,['proof'],machineBits);
    const result=await proveWithZ3(compiler,input,{binary:z3});
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.solverEvidence.length,1);
    const proof=result.solverEvidence[0];
    assert.equal(proof.status,'proved');assert.equal(proof.outcome,'unsat');
    assert.equal(proof.exitCode,0);assert.equal(proof.prover.name,'z3');
    assert.match(proof.prover.version,/^Z3 version /);
    for(const value of [proof.taskFingerprint,proof.programFingerprint,proof.prover.binaryFingerprint,
      proof.prover.fingerprint,proof.runFingerprint])assert.match(value,/^[0-9a-f]{64}$/);
    assert.ok(result.evidence.some(row=>row.stage==='law'&&row.status==='proved'));
    assert.equal(proof.configuration.timeoutMs,5000);
    assert.equal(proof.machineBits,machineBits);
    assert.match(proof.reason,/trusts the typed translation and selected solver/);
    for(const view of ['developer','business','formal','evidence']) {
      const explanation=explainLaw(result.laws[0],result,view);
      assert.equal(explanation.assertion,result.laws[0].assertion);
      assert.deepEqual(explanation.evidence,result.evidence.filter(row=>row.declaration===result.laws[0].id));
    }
  }
});

test('task planning remains separate from the ordinary proof cache and honors known-failing harnesses',requiresZ3,async()=>{
  const input=request(law('true'));
  const checked=await compiler.check(input);
  const planned=await compiler.proofTasks(input);
  const repeated=await compiler.check(input);
  assert.equal(checked.evidence.find(row=>row.stage==='law').status,'proved');
  assert.equal(planned.evidence.find(row=>row.stage==='law').status,'planned');
  assert.deepEqual(repeated,checked);
  const guarded=request(square);
  guarded.sources.push({path:'harness.lawspec',content:'harness smt.testing for smt is for law selected known failing "investigate" end'});
  const result=await proveWithZ3(compiler,guarded,{binary:z3});
  assert.ok(result.diagnostics.some(row=>row.code==='harness'));
  assert.equal(result.solverEvidence[0].outcome,'unsat');
  assert.equal(result.evidence.find(row=>row.stage==='law').status,'known-failing');
});

test('satisfiable Z3 tasks retain unvalidated models without claiming source refutation or nonexistence',requiresZ3,async()=>{
  for(const body of [falseLaw,
    law('there exists (next :: Integer) such that for all (n :: Integer) => next > n end end'),
    law('there does not exist (n :: Integer) such that n / (n - n) = 0 end')]) {
    const result=await proveWithZ3(compiler,request(body),{binary:z3});
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.solverEvidence[0].outcome,'sat');
    assert.equal(result.solverEvidence[0].status,'incomplete');
    assert.equal(result.solverEvidence[0].modelValidated,false);
    assert.equal(typeof result.solverEvidence[0].model,'string');
    assert.ok(result.evidence.filter(row=>row.stage==='law').every(row=>row.status==='incomplete'));
  }
});

test('unsupported translations and unavailable Z3 remain explicit without substituting another theory',async()=>{
  const rational=await proveWithZ3(compiler,request(law('there exists (n :: Rational) such that n * n = 2 end')),{binary:'/missing/z3'});
  assert.deepEqual(rational.diagnostics,[]);
  assert.equal(rational.solverEvidence[0].status,'unsupported');
  assert.match(rational.solverEvidence[0].reason,/Rational quantification/);
  const ieee=await compiler.proofTasks(request(law('for all (n :: Float64) => n = n end')));
  assert.equal(ieee.proofTasks[0].status,'unsupported');
  const unavailable=await proveWithZ3(compiler,request(square),{binary:'/missing/z3'});
  assert.equal(unavailable.solverEvidence[0].outcome,'unavailable');
  assert.equal(unavailable.solverEvidence[0].status,'incomplete');
});

test('Z3 resource limits preserve undecided results and bind changed solver configuration',requiresZ3,async()=>{
  const input=request(square);
  const limited=await proveWithZ3(compiler,input,{binary:z3,resourceLimit:1});
  assert.equal(limited.solverEvidence[0].status,'incomplete');
  assert.ok(['unknown','resource-limit'].includes(limited.solverEvidence[0].outcome));
  const first=await proveWithZ3(compiler,input,{binary:z3,seed:1});
  const second=await proveWithZ3(compiler,input,{binary:z3,seed:2});
  assert.equal(first.solverEvidence[0].taskFingerprint,second.solverEvidence[0].taskFingerprint);
  assert.notEqual(first.solverEvidence[0].prover.fingerprint,second.solverEvidence[0].prover.fingerprint);
  assert.notEqual(first.solverEvidence[0].runFingerprint,second.solverEvidence[0].runFingerprint);
});

test('modified task content cannot reuse a valid compiler task binding',requiresZ3,async()=>{
  const changed={proofTasks:async input=>{
    const result=await compiler.proofTasks(input);
    return {...result,proofTasks:result.proofTasks.map(task=>({...task,script:'(assert false)\n'}))};
  }};
  const result=await proveWithZ3(changed,request(falseLaw),{binary:z3});
  assert.equal(result.solverEvidence[0].outcome,'failed');
  assert.equal(result.solverEvidence[0].status,'incomplete');
  assert.ok(result.evidence.filter(row=>row.stage==='law').every(row=>row.status!=='proved'));
});

test('prover protocol failures and external process termination do not upgrade evidence',async()=>{
  const directory=await mkdtemp(path.join(tmpdir(),'lawspec-proof-'));
  try {
    const binary=path.join(directory,'solver');
    const source='#!/usr/bin/env node\n'+
      'if(process.argv.includes("-version"))console.log("Z3 version 0.0.0 - protocol test");'+
      'else {process.stdout.write("unsat\\n");process.exitCode=7;}\n';
    await writeFile(binary,source);await chmod(binary,0o755);
    const result=await proveWithZ3(compiler,request(falseLaw),{binary});
    assert.equal(result.solverEvidence[0].outcome,'failed');
    assert.equal(result.solverEvidence[0].exitCode,7);
    assert.equal(result.solverEvidence[0].prover.binaryFingerprint,createHash('sha256').update(source).digest('hex'));
    assert.ok(result.evidence.filter(row=>row.stage==='law').every(row=>row.status!=='proved'));
    await writeFile(binary,source.replace('process.stdout.write("unsat\\n");process.exitCode=7;','setInterval(()=>{},1000);'));
    const timeout=await proveWithZ3(compiler,request(falseLaw),{binary,timeoutMs:200});
    assert.equal(timeout.solverEvidence[0].outcome,'timeout');
    assert.equal(timeout.solverEvidence[0].status,'incomplete');
    await writeFile(binary,source.replace('process.stdout.write("unsat\\n");process.exitCode=7;',
      'console.error("out of memory");process.exitCode=1;'));
    const exhausted=await proveWithZ3(compiler,request(falseLaw),{binary});
    assert.equal(exhausted.solverEvidence[0].outcome,'out-of-memory');
    assert.equal(exhausted.solverEvidence[0].status,'incomplete');
  } finally {await rm(directory,{recursive:true,force:true});}
});

test('prove CLI reports selected, unselected, unavailable and mandatory-error outcomes',requiresZ3,async()=>{
  const directory=await mkdtemp(path.join(tmpdir(),'lawspec-prove-cli-'));
  try {
    const cli=new URL('../bin/lawspec.mjs',import.meta.url).pathname;
    const config={version:2,languageProfile:'1.0-rc.1',sources:['input.lawspec'],targets:[],verification:{layers:['proof']}};
    const save=async(body,layers=['proof'])=>{
      await writeFile(path.join(directory,'input.lawspec'),'unit smt\n'+body);
      await writeFile(path.join(directory,'lawspec.json'),JSON.stringify({...config,verification:{layers}}));
    };
    const run=()=>spawnSync(process.execPath,[cli,'prove','--solver',z3,'--json'],{cwd:directory,encoding:'utf8'});
    await save(square);
    const proved=run();assert.equal(proved.status,0,proved.stdout+proved.stderr);
    assert.equal(JSON.parse(proved.stdout).solverEvidence[0].outcome,'unsat');
    await save(falseLaw);
    const candidate=run();assert.equal(candidate.status,2,candidate.stdout+candidate.stderr);
    assert.equal(JSON.parse(candidate.stdout).solverEvidence[0].modelValidated,false);
    await save(square,[]);
    const unselected=run();assert.equal(unselected.status,0,unselected.stdout+unselected.stderr);
    assert.deepEqual(JSON.parse(unselected.stdout).solverEvidence,[]);
    await save(square);
    const absent=spawnSync(process.execPath,[cli,'prove','--solver','/missing/z3','--json'],{cwd:directory,encoding:'utf8'});
    assert.equal(absent.status,2,absent.stdout+absent.stderr);
    assert.equal(JSON.parse(absent.stdout).solverEvidence[0].outcome,'unavailable');
    await save('function broken (n :: Integer) -> Rational is 1 / 0 end function',[]);
    const rejected=run();assert.equal(rejected.status,1,rejected.stdout+rejected.stderr);
    assert.ok(JSON.parse(rejected.stdout).diagnostics.some(row=>row.code==='total'));
  } finally {await rm(directory,{recursive:true,force:true});}
});

test('published proof subpath and task/evidence types admit a real TypeScript consumer',
  {skip:tsc?false:'set LAWSPEC_TSC for the published declaration consumer'},async()=>{
  const directory=await mkdtemp(path.join(tmpdir(),'lawspec-proof-types-'));
  try {
    await writeFile(path.join(directory,'package.json'),'{"type":"module"}');
    const {mkdir}=await import('node:fs/promises');
    await mkdir(path.join(directory,'node_modules'));
    await symlink(new URL('..',import.meta.url).pathname,path.join(directory,'node_modules','lawspec'),'dir');
    await writeFile(path.join(directory,'consumer.ts'),`
import {createCompiler, type CheckRequest} from 'lawspec';
import {proveWithZ3, proofTaskFingerprint, type Z3Options, type SolverEvidence} from 'lawspec/proof';
const compiler=await createCompiler();
const request:CheckRequest={languageProfile:'1.0-rc.1',verification:{layers:['proof']},sources:[]};
const options:Z3Options={binary:'z3',timeoutMs:1000,memoryMb:512,seed:1};
const planned=await compiler.proofTasks(request);
for(const task of planned.proofTasks??[]) {
  if(task.status==='ready') {
    const fingerprint:string=proofTaskFingerprint(task);
    const bits:32|64=task.machineBits;
    console.log(fingerprint,bits,task.script);
  } else console.log(task.reason);
}
const result=await proveWithZ3(compiler,request,options);
for(const item of result.solverEvidence) {
  const status:SolverEvidence['status']=item.status;
  const outcome:SolverEvidence['outcome']=item.outcome;
  console.log(status,outcome,item.prover?.binaryFingerprint,item.modelValidated);
}
// @ts-expect-error solver limits are numeric
const invalid:Z3Options={timeoutMs:'unlimited'};
// @ts-expect-error tasks alone are not completed solver evidence
const evidence:SolverEvidence=planned.proofTasks![0];
`);
    const checked=spawnSync(tsc,['--noEmit','--strict','--target','ES2022','--module','NodeNext',
      '--moduleResolution','NodeNext','consumer.ts'],{cwd:directory,encoding:'utf8'});
    assert.equal(checked.status,0,checked.stdout+checked.stderr);
  } finally {await rm(directory,{recursive:true,force:true});}
});
