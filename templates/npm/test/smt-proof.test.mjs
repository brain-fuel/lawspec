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
const law=body=>'law selected is definition: '+body+' end definition end law';
const request=(body,layers=['proof'],machineBits=64)=>({schemaVersion:5,languageProfile:'1.0-rc.2',
  verification:{layers},machineBits,sources:[{path:'smt-😀.lawspec',content:'unit smt\n'+body+'\nend unit\n'}]});
const square=law('for all (n :: Integer) => n * n >= 0 end for all');
const falseLaw=law('for all (n :: Integer) => n = n + 1 end for all');

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
  const broken=await proveWithZ3(compiler,request(`function broken (n :: Integer) -> Rational is 1 / 0 end function
`,[]),{binary:'/missing/z3'});
  assert.ok(broken.diagnostics.some(row=>row.code==='total'));
  assert.deepEqual(broken.solverEvidence,[]);
});

test('actual Z3 establishes nonlinear and dependent laws from rebuilt-WASM tasks at both widths',requiresZ3,async()=>{
  const samples=[square,
    law('for all (n :: Integer) => there exists (next :: Integer where next > n) such that next = n + 1 end exists end for all'),
    law('there does not exist (n :: Integer) such that n * n < 0 end exists'),
    law('for all (n :: Integer where false) => false end for all')];
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
  guarded.sources.push({path:'harness.lawspec',content:`harness smt.testing for smt is for law selected known failing "investigate"
end for law
end harness
`});
  const result=await proveWithZ3(compiler,guarded,{binary:z3});
  assert.ok(result.diagnostics.some(row=>row.code==='harness'));
  assert.equal(result.solverEvidence[0].outcome,'unsat');
  assert.equal(result.evidence.find(row=>row.stage==='law').status,'known-failing');
});

test('a false law is refuted only at values the reference evaluator confirms',requiresZ3,async()=>{
  for(const machineBits of [32,64]) {
    const result=await proveWithZ3(compiler,request(falseLaw,['proof'],machineBits),{binary:z3});
    assert.deepEqual(result.diagnostics,[]);
    const proof=result.solverEvidence[0];
    assert.equal(proof.outcome,'sat');assert.equal(proof.status,'refuted');
    assert.equal(proof.modelValidated,true);
    assert.equal(proof.counterexample.check,'refuted');
    assert.equal(proof.counterexample.inputs.length,1);
    assert.equal(proof.counterexample.inputs[0].name,'n');
    assert.match(proof.counterexample.inputs[0].value,/^-?[0-9]+$/);
    assert.match(proof.counterexample.runFingerprint,/^[0-9a-f]{64}$/);
    assert.match(proof.reason,/reference evaluator confirms/);
    assert.deepEqual(result.evidence.filter(row=>row.stage==='law').map(row=>row.status),['refuted']);
  }
});

test('v2 data tasks prove record laws and refute a mutant with a confirmed datum',requiresZ3,async()=>{
  const orders=mutant=>`type State is one of | Pending | Shipped | Cancelled end type

type Action is one of | Ship | Cancel end type

function next (state of type State) (action of type Action) -> State is
  first matching case of action:
    when Ship then if state = Pending then Shipped else state end if
    when Cancel then ${mutant?'Cancelled':'if state = Shipped then Shipped else Cancelled end if'}
  end case
end function
`+law('for all (state :: State) (action :: Action) => state = Shipped implies next state action = Shipped end for all')+`
laws for next are
  partial because "only shipped orders are checked here"
end laws
`;
  const proved=await proveWithZ3(compiler,request(orders(false)),{binary:z3});
  assert.equal(proved.solverEvidence[0].encoding,'lawspec-smtlib-v2');
  assert.equal(proved.solverEvidence[0].status,'proved');
  const refuted=await proveWithZ3(compiler,request(orders(true)),{binary:z3});
  const proof=refuted.solverEvidence[0];
  assert.equal(proof.status,'refuted');
  assert.deepEqual(proof.counterexample.inputs,[{name:'state',value:'Shipped'},{name:'action',value:'Cancel'}]);
});

test('law sets: Z3 settles completeness, overlap and conflict, and the evaluator confirms every input',requiresZ3,async()=>{
  const {readFile}=await import('node:fs/promises');
  const content=await readFile(new URL('../../test/fixtures/law-sets.lawspec',import.meta.url),'utf8');
  const result=await proveWithZ3(compiler,{schemaVersion:5,languageProfile:'1.0-rc.2',verification:{layers:['proof']},
    sources:[{path:'portfolio.lawspec',content}]},{binary:z3});
  const row=(name,stage)=>result.evidence.find(r=>r.declaration==='portfolio.refunds::'+name&&r.stage===stage);
  for(const stage of ['completeness','overlap','conflict','vacuity'])assert.equal(row('decide',stage).status,'proved');
  assert.equal(row('settle','conflict').status,'refuted');
  assert.match(row('settle','conflict').reason,/amount = 0, captured = 0; Z3 found it and the evaluator confirms it/);
  assert.ok(result.diagnostics.some(d=>d.code==='refuted'));
  assert.equal(row('settle','overlap').status,'exempted');
  assert.equal(row('quote','completeness').status,'proved');
  assert.equal(row('triage','completeness').status,'exempted');
  assert.match(row('triage','completeness').reason,/not covered: amount = 5001/);
  assert.equal(row('triage','completeness').exemption.reason,'amounts above 5000 go to manual review');
  assert.ok(result.solverEvidence.some(e=>e.kind==='analysis'&&e.stage==='conflict'&&e.status==='refuted'&&e.outcome==='sat'));
});

test('recursive definitions: guarded axioms with fuel first, then define-fun-rec, recorded in the evidence',requiresZ3,async()=>{
  const count=`function count (xs :: List Int32) -> Whole is
  first matching case of xs :
    when Nil then 0
    when Cons head tail then 1 + count tail
  end case
end function
`;
  const unfolded=await proveWithZ3(compiler,request(count+law('for all (x :: Int32) (xs :: List Int32) => count (Cons x xs) = 1 + count xs end for all')),{binary:z3});
  const byAxioms=unfolded.solverEvidence[0];
  assert.equal(byAxioms.status,'proved');
  assert.deepEqual(byAxioms.recursion,{encoding:'guarded-axioms',fuel:2});
  assert.deepEqual(byAxioms.attempts.map(a=>a.outcome),['unsat']);
  // Plain words for people; the IR keeps the SMT names.
  assert.match(byAxioms.reason,/by unfolding step by step up to 2 times/);
  const deeper=await proveWithZ3(compiler,request(count+law('count [1, 2, 3] = 3')),{binary:z3});
  const byRecursion=deeper.solverEvidence[0];
  assert.equal(byRecursion.status,'proved');
  assert.deepEqual(byRecursion.recursion,{encoding:'define-fun-rec'});
  assert.deepEqual(byRecursion.attempts.map(a=>[a.recursion.encoding,a.outcome]),[['guarded-axioms','unknown'],['define-fun-rec','unsat']]);
  assert.equal(byRecursion.taskFingerprint,byRecursion.attempts[1].taskFingerprint);
  assert.equal(deeper.evidence.find(row=>row.stage==='law').status,'proved');
  // Obviously false laws get a counterexample the evaluator confirms.
  const empty=await proveWithZ3(compiler,request(count+law('for all (xs :: List Int32) => count xs > 0 end for all')),{binary:z3});
  assert.equal(empty.solverEvidence[0].status,'refuted');
  assert.deepEqual(empty.solverEvidence[0].counterexample.inputs,[{name:'xs',value:'Nil'}]);
  const ground=await proveWithZ3(compiler,request(count+law('count [1, 2] = 3')),{binary:z3});
  assert.equal(ground.solverEvidence[0].status,'refuted');
  assert.match(ground.solverEvidence[0].reason,/the law has no inputs/);
});

const lists=`function count (xs :: List Int32) -> Whole is
  first matching case of xs :
    when Nil then 0
    when Cons head tail then 1 + count tail
  end case
end function

function append (xs :: List Int32) (ys :: List Int32) -> List Int32 is
  first matching case of xs :
    when Nil then ys
    when Cons head tail then Cons head (append tail ys)
  end case
end function

function reverse (xs :: List Int32) -> List Int32 is
  first matching case of xs :
    when Nil then []
    when Cons head tail then append (reverse tail) [head]
  end case
end function

law "|append adds lengths| is definition: for all (xs :: List Int32) (ys :: List Int32) => count (append xs ys) = count xs + count ys end for all end definition end law
law "|append nil| is definition: for all (xs :: List Int32) => append xs [] = xs end for all end definition end law
law "|append associates| is definition: for all (xs :: List Int32) (ys :: List Int32) (zs :: List Int32) => append (append xs ys) zs = append xs (append ys zs) end for all end definition end law
law "|reverse of append| is definition: for all (xs :: List Int32) (ys :: List Int32) => reverse (append xs ys) = append (reverse ys) (reverse xs) end for all end definition end law
law "|reverse twice| is definition: for all (xs :: List Int32) => reverse (reverse xs) = xs end for all end definition end law

laws for append are
  partial because "only appending the empty list is stated"
end laws
`;
const harness=blocks=>'\nharness smt.proofs for smt is\n'+blocks.map(([name,lines])=>`for law "|${name}|\n`+lines.map(l=>'  '+l+'\n').join('')+'end for law\n').join('')+'end harness\n';

test('induction: each case has its own receipt, and a law rests on the laws it cites',requiresZ3,async()=>{
  const proved=await proveWithZ3(compiler,request(lists+harness([
    ['append adds lengths',['prove by induction on xs']],
    ['append associates',['prove by induction on xs']],
    ['reverse of append',['prove by induction on xs','  using "|append nil|, "|append associates|']],
    ['reverse twice',['prove by induction on xs','  using "|reverse of append|']]])),{binary:z3});
  assert.deepEqual(proved.diagnostics,[]);
  const of=name=>proved.solverEvidence.find(e=>e.declaration==='smt::law::"|'+name+'|');
  for(const name of ['append adds lengths','append nil','append associates','reverse of append','reverse twice'])
    assert.equal(of(name).status,'proved',name+': '+of(name).reason);
  const lengths=of('append adds lengths');
  assert.deepEqual(lengths.induction.cases.map(c=>[c.case,c.outcome]),[['xs = Nil','unsat'],['xs = Cons','unsat']]);
  for(const c of lengths.induction.cases)assert.match(c.runFingerprint,/^[0-9a-f]{64}$/);
  assert.match(lengths.reason,/by induction on xs/);
  assert.deepEqual(of('reverse twice').induction.using,['smt::law::"|reverse of append|']);
  assert.equal(proved.evidence.find(r=>r.declaration==='smt::law::"|reverse twice|').status,'proved');
  // Without its own induction, the cited law is not proved, and neither is
  // the law that cites it.
  const resting=await proveWithZ3(compiler,request(lists+harness([
    ['reverse of append',['prove without induction']],
    ['reverse twice',['prove by induction on xs','  using "|reverse of append|']]])),{binary:z3});
  const twice=resting.solverEvidence.find(e=>e.declaration==='smt::law::"|reverse twice|');
  assert.equal(twice.status,'incomplete');
  assert.match(twice.reason,/it cites "\|reverse of append\|, which is incomplete/);
});

test('an induction case whose model the law survives says the hypothesis is too weak',async()=>{
  const directory=await mkdtemp(path.join(tmpdir(),'lawspec-induction-'));
  try {
    // Satisfiable for induction cases only, with the empty list as the model.
    const binary=path.join(directory,'solver');
    await writeFile(binary,'#!/bin/sh\nif [ "$1" = "-version" ]; then echo "Z3 version 0.0.0 - induction test"; exit 0; fi\n'+
      'case=\nwhile IFS= read -r line; do case "$line" in *"induction on"*) case=1;; *"(check-sat)"*) break;; esac; done\n'+
      'if [ -n "$case" ]; then echo sat; read -r line; echo "((lawspec_input_0 |List<Int32>#Nil|))"; else echo unknown; read -r line; echo \'(:reason-unknown "test")\'; fi\n');
    await chmod(binary,0o755);
    const result=await proveWithZ3(compiler,request(lists.split('\nlaw ')[0]+'\n'+law('for all (xs :: List Int32) => count xs >= 0 end for all')),{binary});
    const item=result.solverEvidence[0];
    assert.equal(item.status,'incomplete');
    assert.match(item.reason,/induction hypothesis is too weak/);
    assert.ok(!result.diagnostics.some(d=>d.code==='proof-translation'));
  } finally {await rm(directory,{recursive:true,force:true});}
});

test('text laws: proved over strings, and refuted with a text the evaluator confirms',requiresZ3,async()=>{
  const proved=await proveWithZ3(compiler,request(law('for all (a :: Text) (b :: Text) => prelude.length (a ++ b) = prelude.length a + prelude.length b end for all')),{binary:z3});
  assert.equal(proved.solverEvidence[0].status,'proved');
  assert.equal(proved.solverEvidence[0].encoding,'lawspec-smtlib-v2');
  const refuted=await proveWithZ3(compiler,request(law('for all (t :: Text) => (t ++ "!") starts with "a" end for all')),{binary:z3});
  assert.equal(refuted.solverEvidence[0].status,'refuted');
  assert.equal(refuted.solverEvidence[0].counterexample.inputs[0].name,'t');
  const high=await proveWithZ3(compiler,request(law('for all (t :: Text) => t != "\u{30000}" end for all')),{binary:z3});
  assert.equal(high.solverEvidence[0].status,'unsupported');
  assert.match(high.solverEvidence[0].reason,/above U\+2FFFF/);
});

test('numbers: exact rational witnesses, and IEEE floats refuted by a float the evaluator confirms',requiresZ3,async()=>{
  const third=await proveWithZ3(compiler,request(law('there exists (x :: Rational) such that 3 * x = 1 end exists')),{binary:z3});
  assert.equal(third.solverEvidence[0].status,'proved');
  const grows=await proveWithZ3(compiler,request(law('for all (x :: Float64 where prelude.isFinite x) => x + 1.0 > x end for all')),{binary:z3});
  assert.equal(grows.solverEvidence[0].status,'refuted');
  const nan=await proveWithZ3(compiler,request(law('for all (x :: Float64) => prelude.isNaN x implies x != x end for all')),{binary:z3});
  assert.equal(nan.solverEvidence[0].status,'proved');
});

test('satisfiable Z3 tasks whose values cannot be confirmed stay incomplete',requiresZ3,async()=>{
  for(const body of [
    law('there exists (next :: Integer) such that for all (n :: Integer) => next > n end for all end exists'),
    law('there does not exist (n :: Integer) such that n / (n - n) = 0 end exists')]) {
    const result=await proveWithZ3(compiler,request(body),{binary:z3});
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.solverEvidence[0].outcome,'sat');
    assert.equal(result.solverEvidence[0].status,'incomplete');
    assert.equal(result.solverEvidence[0].modelValidated,false);
    assert.equal(typeof result.solverEvidence[0].model,'string');
    assert.equal(result.solverEvidence[0].counterexample.check,'incomplete');
    assert.ok(result.evidence.filter(row=>row.stage==='law').every(row=>row.status==='incomplete'));
  }
});

test('a broken counterexample translation gives model-not-confirmed, never refuted',requiresZ3,async()=>{
  const frame=value=>Buffer.byteLength(value,'utf8')+':'+value;
  const bind=values=>createHash('sha256').update(values.map(frame).join('')).digest('hex');
  const mutant={proofTasks:async input=>{
    const result=await compiler.proofTasks(input);
    if(input.proofCounterexamples)return result;
    return {...result,proofTasks:result.proofTasks.map(task=>{
      const script=task.counterexample.script.replace(/\(assert \(not [^\n]*\)\n$/,'(assert (= lawspec_input_0 3))\n');
      return {...task,counterexample:{...task.counterexample,script,fingerprint:bind(['lawspec-smtlib-v2',
        task.programFingerprint,String(task.machineBits),task.owner,task.declaration,script])}};
    })};
  }};
  const result=await proveWithZ3(mutant,request(law('for all (n :: Integer) => n * n != 4 end for all')),{binary:z3});
  const proof=result.solverEvidence[0];
  assert.equal(proof.outcome,'sat');assert.equal(proof.status,'incomplete');
  assert.equal(proof.counterexample.check,'model-not-confirmed');
  assert.ok(result.diagnostics.some(row=>row.code==='proof-translation'));
});

test('unsupported translations and unavailable Z3 remain explicit without substituting another theory',async()=>{
  const native=await proveWithZ3(compiler,request('external :: Integer -> Integer\n'+law('for all (n :: Integer) => external n = external n end for all')),{binary:'/missing/z3'});
  assert.deepEqual(native.diagnostics,[]);
  assert.equal(native.solverEvidence[0].status,'unsupported');
  assert.match(native.solverEvidence[0].reason,/native implementations stay unsupported/);
  // Rational and IEEE laws have tasks; without Z3 they stay incomplete.
  const rational=await proveWithZ3(compiler,request(law('there exists (n :: Rational) such that n * n = 2 end exists')),{binary:'/missing/z3'});
  assert.equal(rational.solverEvidence[0].status,'incomplete');
  assert.equal(rational.solverEvidence[0].outcome,'unavailable');
  const ieee=await compiler.proofTasks(request(law('for all (n :: Float64) => n = n end for all')));
  assert.equal(ieee.proofTasks[0].status,'ready');
  assert.equal(ieee.proofTasks[0].encoding,'lawspec-smtlib-v2');
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
    // A shell script, so what is measured is the host's protocol handling,
    // not how long an interpreter takes to start on a busy machine.
    const solver=task=>'#!/bin/sh\nif [ "$1" = "-version" ]; then echo "Z3 version 0.0.0 - protocol test"; exit 0; fi\n'+task+'\n';
    const source=solver("printf 'unsat\\n'; exit 7");
    await writeFile(binary,source);await chmod(binary,0o755);
    const result=await proveWithZ3(compiler,request(falseLaw),{binary});
    assert.equal(result.solverEvidence[0].outcome,'failed');
    assert.equal(result.solverEvidence[0].exitCode,7);
    assert.equal(result.solverEvidence[0].prover.binaryFingerprint,createHash('sha256').update(source).digest('hex'));
    assert.ok(result.evidence.filter(row=>row.stage==='law').every(row=>row.status!=='proved'));
    await writeFile(binary,solver('while :; do sleep 1; done'));
    const timeout=await proveWithZ3(compiler,request(falseLaw),{binary,timeoutMs:200});
    // The task's run timed out, not the identity probe before it.
    assert.equal(timeout.solverEvidence[0].prover?.version,'Z3 version 0.0.0 - protocol test');
    assert.equal(timeout.solverEvidence[0].outcome,'timeout');
    assert.equal(timeout.solverEvidence[0].status,'incomplete');
    await writeFile(binary,solver('echo "out of memory" >&2; exit 1'));
    const exhausted=await proveWithZ3(compiler,request(falseLaw),{binary});
    assert.equal(exhausted.solverEvidence[0].outcome,'out-of-memory');
    assert.equal(exhausted.solverEvidence[0].status,'incomplete');
  } finally {await rm(directory,{recursive:true,force:true});}
});

test('prove CLI reports selected, unselected, unavailable and mandatory-error outcomes',requiresZ3,async()=>{
  const directory=await mkdtemp(path.join(tmpdir(),'lawspec-prove-cli-'));
  try {
    const cli=new URL('../bin/lawspec.mjs',import.meta.url).pathname;
    const config={version:2,languageProfile:'1.0-rc.2',sources:['input.lawspec'],targets:[],verification:{layers:['proof']}};
    const save=async(body,layers=['proof'])=>{
      await writeFile(path.join(directory,'input.lawspec'),'unit smt\n'+body+'\nend unit\n');
      await writeFile(path.join(directory,'lawspec.json'),JSON.stringify({...config,verification:{layers}}));
    };
    const run=()=>spawnSync(process.execPath,[cli,'prove','--solver',z3,'--json'],{cwd:directory,encoding:'utf8'});
    await save(square);
    const proved=run();assert.equal(proved.status,0,proved.stdout+proved.stderr);
    assert.equal(JSON.parse(proved.stdout).solverEvidence[0].outcome,'unsat');
    await save(falseLaw);
    const candidate=run();assert.equal(candidate.status,1,candidate.stdout+candidate.stderr);
    assert.equal(JSON.parse(candidate.stdout).solverEvidence[0].status,'refuted');
    assert.equal(JSON.parse(candidate.stdout).solverEvidence[0].modelValidated,true);
    await save(law('for all (n :: Int8 where n >= 0 and n <= 20) => n < 10 end for all'),['exhaustive']);
    const evidence=spawnSync(process.execPath,[cli,'evidence'],{cwd:directory,encoding:'utf8'});
    assert.equal(evidence.status,1,evidence.stdout+evidence.stderr);
    assert.match(evidence.stdout,/REFUTED \(1\)/);
    assert.match(evidence.stdout,/is false for n = 10/);
    await save(`type State is one of | Pending | Shipped | Cancelled end type
function next (state :: State) -> State is if state = Pending then Shipped else state end if end function
law "|pending orders ship| is definition: for all (state :: State) => state = Pending implies next state = Shipped end for all end definition end law
laws for next are
  partial until 1.2.0 because "cancelled orders come later"
end laws
`,['exhaustive']);
    await writeFile(path.join(directory,'lawspec.json'),JSON.stringify({...config,projectVersion:'1.1.4',verification:{layers:['exhaustive']}}));
    const exempted=spawnSync(process.execPath,[cli,'evidence'],{cwd:directory,encoding:'utf8'});
    assert.equal(exempted.status,0,exempted.stdout+exempted.stderr);
    assert.match(exempted.stdout,/EXEMPTED \(1\)/);
    assert.match(exempted.stdout,/until 1\.2\.0 \(project is 1\.1\.4\)/);
    await writeFile(path.join(directory,'lawspec.json'),JSON.stringify({...config,projectVersion:'1.2.0',verification:{layers:['exhaustive']}}));
    const expired=spawnSync(process.execPath,[cli,'evidence'],{cwd:directory,encoding:'utf8'});
    assert.equal(expired.status,1,expired.stdout+expired.stderr);
    assert.match(expired.stdout,/REFUTED \(1\)/);
    await save(square,[]);
    const unselected=run();assert.equal(unselected.status,0,unselected.stdout+unselected.stderr);
    assert.deepEqual(JSON.parse(unselected.stdout).solverEvidence,[]);
    await save(square);
    const absent=spawnSync(process.execPath,[cli,'prove','--solver','/missing/z3','--json'],{cwd:directory,encoding:'utf8'});
    assert.equal(absent.status,2,absent.stdout+absent.stderr);
    assert.equal(JSON.parse(absent.stdout).solverEvidence[0].outcome,'unavailable');
    await save(`function broken (n :: Integer) -> Rational is 1 / 0 end function
`,[]);
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
const request:CheckRequest={languageProfile:'1.0-rc.2',verification:{layers:['proof']},sources:[]};
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
for(const item of result.solverEvidence) {
  if(item.kind==='analysis') {
    const stage:'completeness'|'overlap'|'conflict'|'vacuity'=item.stage;
    const status:'proved'|'refuted'|'exempted'|'incomplete'|'unsupported'=item.status;
    console.log(stage,status,item.check);
    // @ts-expect-error a law-set task has no law location
    console.log(item.at);
  } else {
    const at=item.at;const bits:32|64=item.machineBits;
    // @ts-expect-error a law's task is never exempted
    const exempted:typeof item.status='exempted';
    console.log(at,bits,exempted,item.counterexample?.check);
  }
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
