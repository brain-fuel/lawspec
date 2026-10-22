// Host execution of compiler-produced tasks. The browser/WASM compiler stays
// pure; this Node host invokes Z3's SMT-LIB interface without a shell.
import {spawn} from 'node:child_process';
import {createHash} from 'node:crypto';
import {access,readFile,realpath} from 'node:fs/promises';
import {constants} from 'node:fs';
import path from 'node:path';

const hash=value=>createHash('sha256').update(value).digest('hex');
const frame=value=>Buffer.byteLength(value,'utf8')+':'+value;
const fingerprint=values=>hash(values.map(frame).join(''));
// v1 is frozen byte for byte; tasks that need later features are v2.
const encodings=['lawspec-smtlib-v1','lawspec-smtlib-v2'];

export function proofTaskFingerprint(task) {
  return fingerprint([task.encoding,task.programFingerprint,String(task.machineBits),
    task.owner,task.declaration,task.script]);
}

function optionsWithDefaults(options) {
  const config={binary:options.binary??'z3',timeoutMs:options.timeoutMs??5000,
    memoryMb:options.memoryMb??512,resourceLimit:options.resourceLimit??0,
    seed:options.seed??0,maxOutputBytes:options.maxOutputBytes??1048576};
  for(const [key,maximum] of [['timeoutMs',600000],['memoryMb',65536],
    ['resourceLimit',2147483647],['seed',2147483647],['maxOutputBytes',16777216]]) {
    const minimum=['resourceLimit','seed'].includes(key)?0:1;
    if(!Number.isSafeInteger(config[key])||config[key]<minimum||config[key]>maximum)
      throw new TypeError(`Invalid Z3 ${key}`);
  }
  if(typeof config.binary!=='string'||!config.binary||config.binary.includes('\0'))
    throw new TypeError('Invalid Z3 executable');
  return config;
}

async function executable(binary) {
  const candidates=path.isAbsolute(binary)||binary.includes('/')||binary.includes('\\')
    ?[path.resolve(binary)]
    :(process.env.PATH??'').split(path.delimiter).map(folder=>path.resolve(folder,binary));
  for(const candidate of candidates) {
    try {await access(candidate,constants.X_OK);return await realpath(candidate);}
    catch(error) {if(!['ENOENT','EACCES','ENOTDIR'].includes(error.code))throw error;}
  }
  throw Object.assign(new Error(`Z3 executable is unavailable: ${binary}`),{code:'ENOENT'});
}

// Only the first response line is a protocol token. Models and unknown reasons
// remain raw prover output; this host does not implement another SMT parser.
const followUp=token=>token==='sat'?'(get-model)\n(exit)\n':
  token==='unknown'?'(get-info :reason-unknown)\n(exit)\n':'(exit)\n';
function execute(binary,args,initial,config,interactive=false,finishFor=followUp) {
  return new Promise(resolve=>{
    const started=performance.now();
    const child=spawn(binary,args,{stdio:['pipe','pipe','pipe'],shell:false});
    child.stdout.setEncoding('utf8');child.stderr.setEncoding('utf8');
    let stdout='',stderr='',input=initial,bytes=0,outcome=null,error=null;
    let timeout=false,outputLimit=false,answered=false,closed=false;
    const timer=setTimeout(()=>{timeout=true;child.kill('SIGKILL');},config.timeoutMs);
    const append=(which,chunk)=>{
      bytes+=Buffer.byteLength(chunk,'utf8');
      if(bytes>config.maxOutputBytes){outputLimit=true;child.kill('SIGKILL');return;}
      if(which==='stdout')stdout+=chunk;else stderr+=chunk;
      if(interactive&&!answered&&stdout.includes('\n')) {
        answered=true;
        const token=stdout.slice(0,stdout.indexOf('\n')).trim();
        if(['sat','unsat','unknown'].includes(token))outcome=token;
        else error='unexpected Z3 protocol response';
        const finish=finishFor(token);
        input+=finish;
        child.stdin.end(finish);
      }
    };
    child.stdout.on('data',chunk=>append('stdout',chunk));
    child.stderr.on('data',chunk=>append('stderr',chunk));
    child.stdin.on('error',problem=>{if(problem.code!=='EPIPE')error=problem.message;});
    child.on('error',problem=>{error=problem.message;});
    child.on('close',(exitCode,signal)=>{
      if(closed)return;
      closed=true;clearTimeout(timer);
      resolve({stdout,stderr,input,outcome,error,timeout,outputLimit,exitCode,signal,
        elapsedMs:performance.now()-started});
    });
    if(interactive)child.stdin.write(initial);else child.stdin.end(initial);
  });
}

const versionProbeMs=30000;
async function prover(config) {
  const binary=await executable(config.binary);
  const binaryFingerprint=hash(await readFile(binary));
  // The identity probe has its own bound: the task limit is for a solver's
  // work on a task, and the probe does none.
  const versionRun=await execute(binary,['-version'],'',{...config,timeoutMs:versionProbeMs});
  const version=versionRun.stdout.trim();
  if(versionRun.exitCode!==0||versionRun.error||versionRun.timeout||versionRun.outputLimit||
      !/^Z3 version [0-9]+\.[0-9]+/.test(version))
    throw Object.assign(new Error('The selected executable did not return a successful Z3 version response'),
      {outcome:versionRun.timeout?'timeout':'failed'});
  const args=['-in','-smt2',`-t:${config.timeoutMs}`,`-memory:${config.memoryMb}`];
  const identity=fingerprint([binaryFingerprint,version,JSON.stringify(args),JSON.stringify(config)]);
  return {binary,binaryFingerprint,version,args,fingerprint:identity};
}

function validTask(task) {
  return encodings.includes(task.encoding)&&[32,64].includes(task.machineBits)&&
    ['owner','declaration','programFingerprint','script','taskFingerprint'].every(key=>typeof task[key]==='string')&&
    /^[0-9a-f]{64}$/.test(task.programFingerprint)&&
    proofTaskFingerprint(task)===task.taskFingerprint;
}

// A task over recursive definitions names its encoding and carries the
// other one: by unfolding step by step (guarded axioms with fuel, in the
// IR) and by solver recursion (define-fun-rec). The host tries them in the
// order the law's harness gives, by default unfolding first. A law may also
// be proved by induction on an input: each case is its own task, tried in
// the same encodings, and the law is proved only when every case is. The
// evidence records which encoding proved the law, and every attempt.
// Programmers read plain words; the IR keeps the SMT names.
const recursionName=recursion=>recursion?.encoding==='guarded-axioms'?`unfolding step by step up to ${recursion.fuel} times`:
  recursion?.encoding==='define-fun-rec'?'solver recursion':'';
async function solve(task,selected,config) {
  const first=await attempt(task,task.script,task.taskFingerprint,selected,config);
  if(!task.recursion&&!task.induction)return first;
  if(first.status==='unsupported'||(first.status==='incomplete'&&first.outcome==='failed'&&!first.prover))return first;
  const tried=[{recursion:task.recursion,taskFingerprint:task.taskFingerprint,outcome:first.outcome,runFingerprint:first.runFingerprint,elapsedMs:first.elapsedMs}];
  if(first.outcome==='unsat')
    return {...first,recursion:task.recursion,attempts:tried,reason:first.reason+(task.recursion?'; by '+recursionName(task.recursion):'')};
  let best={...first,recursion:task.recursion,attempts:tried};
  const alternative=task.alternative;
  if(alternative&&!selected.error) {
    if(typeof alternative.script!=='string'||proofTaskFingerprint({...task,script:alternative.script})!==alternative.taskFingerprint)
      return {...best,reason:first.reason+'; the alternative encoding\'s binding is invalid'};
    const second=await attempt(task,alternative.script,alternative.taskFingerprint,selected,config);
    tried.push({recursion:alternative.recursion,taskFingerprint:alternative.taskFingerprint,outcome:second.outcome,
      runFingerprint:second.runFingerprint,elapsedMs:second.elapsedMs});
    if(second.outcome==='unsat')
      return {...second,taskFingerprint:alternative.taskFingerprint,recursion:alternative.recursion,attempts:tried,
        reason:second.reason+'; by '+recursionName(alternative.recursion)+' after '+recursionName(task.recursion)+' gave '+first.outcome};
    best={...best,reason:first.reason+'; '+recursionName(alternative.recursion)+' gave '+second.outcome};
  }
  const induction=task.induction;
  if(!induction||selected.error)return best;
  if(induction.status!=='ready')
    return {...best,induction:{on:induction.on,using:induction.using,cases:[]},reason:best.reason+'; induction on '+induction.on+' is unsupported: '+induction.reason};
  const cases=[];
  for(const item of induction.cases) {
    const bound=caseTask=>proofTaskFingerprint({...task,script:caseTask.script})===caseTask.taskFingerprint;
    if(typeof item.script!=='string'||!bound(item)) {
      cases.push({case:item.case,outcome:'failed',reason:'the case\'s binding is invalid'});continue;
    }
    const runs=[{recursion:item.recursion,script:item.script,taskFingerprint:item.taskFingerprint},
      ...(item.alternative&&typeof item.alternative.script==='string'&&bound(item.alternative)?
        [{recursion:item.alternative.recursion,script:item.alternative.script,taskFingerprint:item.alternative.taskFingerprint}]:[])];
    const receipt={case:item.case,attempts:[]};
    for(const run of runs) {
      const done=await attempt(task,run.script,run.taskFingerprint,selected,config,item.inputs);
      receipt.attempts.push({recursion:run.recursion,taskFingerprint:run.taskFingerprint,outcome:done.outcome,
        runFingerprint:done.runFingerprint,elapsedMs:done.elapsedMs});
      Object.assign(receipt,{outcome:done.outcome,recursion:run.recursion,taskFingerprint:run.taskFingerprint,runFingerprint:done.runFingerprint});
      if(done.values&&!receipt.values)receipt.values=done.values;
      if(done.outcome==='unsat')break;
    }
    cases.push(receipt);
  }
  const record={on:induction.on,using:induction.using,asked:induction.asked,cases};
  if(cases.every(c=>c.outcome==='unsat'))
    return {...best,status:'proved',outcome:'unsat',induction:record,model:undefined,modelValidated:undefined,
      reason:'Z3 established this law by induction on '+induction.on+', every case: '+cases.map(c=>c.case+' by '+recursionName(c.recursion)).join(', ')+
        (induction.using.length?'; citing '+induction.using.map(law=>law.split('::law::').pop()).join(', '):'')+
        '; trusts the typed translation and selected solver, without a kernel-checked certificate'};
  const open=cases.filter(c=>c.outcome!=='unsat');
  return {...best,induction:record,reason:best.reason+'; induction on '+induction.on+': '+open.map(c=>'case '+c.case+' gave '+c.outcome).join(', ')};
}

async function attempt(task,script,taskFingerprint,selected,config,names=null) {
  const common={owner:task.owner,declaration:task.declaration,at:task.at,
    programFingerprint:task.programFingerprint,taskFingerprint:task.taskFingerprint,
    encoding:task.encoding,machineBits:task.machineBits,configuration:config};
  if(task.status==='unsupported')return {...common,status:'unsupported',outcome:'unsupported',reason:task.reason};
  if(task.status!=='ready'||!validTask(task))
    return {...common,status:'incomplete',outcome:'failed',reason:'Compiler proof task binding is invalid'};
  if(selected.error)return {...common,status:'incomplete',outcome:selected.outcome,reason:selected.error};
  const input=`(set-option :print-success false)\n(set-option :produce-models true)\n`+
    `(set-option :random-seed ${config.seed})\n(set-option :rlimit ${config.resourceLimit})\n`+
    script+'(check-sat)\n';
  // An induction case asks for the law's inputs, so its model can be
  // checked as the law's counterexample.
  const run=await execute(selected.binary,selected.args,input,config,true,names?.length?
    token=>token==='sat'?`(get-value (${names.join(' ')}))\n(exit)\n`:followUp(token):followUp);
  let unchanged=false;
  try {unchanged=hash(await readFile(selected.binary))===selected.binaryFingerprint;} catch {}
  const metadata={...common,prover:{name:'z3',version:selected.version,
    binary:selected.binary,binaryFingerprint:selected.binaryFingerprint,
    fingerprint:selected.fingerprint,arguments:selected.args},configuration:config,
    runFingerprint:fingerprint([taskFingerprint,selected.fingerprint,run.input]),
    elapsedMs:run.elapsedMs,exitCode:run.exitCode,signal:run.signal,
    stdout:run.stdout,stderr:run.stderr};
  let outcome=run.outcome,reason;
  if(!unchanged){outcome='failed';reason='Z3 executable changed during execution';}
  else if(run.timeout){outcome='timeout';reason='Z3 exceeded the host wall-clock limit';}
  else if(run.outputLimit){outcome='failed';reason='Z3 exceeded the output limit';}
  else if(run.exitCode!==0&&/out of memory|out_of_memory/i.test(run.stdout+'\n'+run.stderr)) {
    outcome='out-of-memory';reason='Z3 reported memory exhaustion';
  } else if(run.error||run.exitCode!==0||!outcome||run.stdout.includes('(error ')) {
    outcome='failed';reason=run.error??'Z3 did not complete the task protocol successfully';
  } else if(outcome==='unsat')reason='Z3 established this law, including required definedness; trusts the typed translation and selected solver, without a kernel-checked certificate';
  else if(outcome==='sat')reason='Z3 returned a satisfying model for the negated proof task; it has not been validated as a LawSpec counterexample';
  else {
    reason='Z3 could not decide this task: '+run.stdout.slice(run.stdout.indexOf('\n')+1).trim();
    if(/:reason-unknown\s+"timeout"/.test(run.stdout))outcome='timeout';
    else if(/:reason-unknown\s+"max\. resource limit exceeded"/.test(run.stdout))outcome='resource-limit';
  }
  const model=run.outcome==='sat'?run.stdout.slice(run.stdout.indexOf('\n')+1).trim():null;
  return {...metadata,status:outcome==='unsat'?'proved':'incomplete',outcome,reason,
    ...(model!==null&&!names?.length?{model,modelValidated:false}:{}),...(model!==null&&names?.length?{values:model}:{})};
}

// A satisfiable task's model is not a counterexample. Z3 runs the task's
// counterexample query (lawspec-smtlib-v2) and gives the values of the law's
// outer inputs; the compiler, not this host, reads them and re-checks the law
// at them with its reference evaluator.
async function counterexampleValues(task,selected,config) {
  const query=task.counterexample;
  if(!query||typeof query.script!=='string'||!Array.isArray(query.inputs))return null;
  if(fingerprint(['lawspec-smtlib-v2',task.programFingerprint,String(task.machineBits),task.owner,task.declaration,
    query.script])!==query.fingerprint)return null;
  const names=query.inputs.map(input=>input.name);
  // A law with no inputs needs no search: the evaluator decides it.
  if(!names.length)return {outcome:'sat',values:'()',fingerprint:query.fingerprint,runFingerprint:null};
  const input=`(set-option :print-success false)\n(set-option :produce-models true)\n`+
    `(set-option :random-seed ${config.seed})\n(set-option :rlimit ${config.resourceLimit})\n`+
    query.script+'(check-sat)\n';
  const run=await execute(selected.binary,selected.args,input,config,true,
    token=>token==='sat'&&names.length?`(get-value (${names.join(' ')}))\n(exit)\n`:'(exit)\n');
  if(run.outcome!=='sat'||run.timeout||run.outputLimit||run.error||run.exitCode!==0)
    return {outcome:run.outcome??'failed',stdout:run.stdout};
  return {outcome:'sat',values:names.length?run.stdout.slice(run.stdout.indexOf('\n')+1).trim():'()',
    fingerprint:query.fingerprint,runFingerprint:fingerprint([query.fingerprint,selected.fingerprint,run.input])};
}

// Tasks always come freshly from the compiler for the supplied source request.
// An imported JSON solver report cannot upgrade a law's evidence through here.
export async function proveWithZ3(compiler,request,options={}) {
  const config=optionsWithDefaults(options);
  const result=await compiler.proofTasks(request);
  if(result.diagnostics?.length)return {...result,solverEvidence:[]};
  const tasks=result.proofTasks??[];
  let selected={};
  const analysis=result.analysisTasks??[];
  if(tasks.some(task=>task.status==='ready')||analysis.some(row=>row.status==='ready')) {
    try {selected=await prover(config);}
    catch(error){selected={error:error.message,outcome:error.code==='ENOENT'?'unavailable':error.outcome??'failed'};}
  }
  const solverEvidence=[];
  for(const task of tasks)solverEvidence.push(await solve(task,selected,config));
  const diagnostics=[...(result.diagnostics??[])];
  // Values to check as each unproved law's counterexample: the
  // counterexample query's (run whenever a law's task was satisfiable, and
  // for every unproved law over recursive definitions, since Z3 unfolds
  // freely there), then each induction case's model.
  const searched=[];
  for(const [index,item] of solverEvidence.entries()) {
    const task=tasks[index];
    if(['proved','unsupported'].includes(item.status)||selected.error)continue;
    if(item.outcome==='sat'||task.recursion) {
      const found=await counterexampleValues(task,selected,config);
      if(found?.outcome==='sat')searched.push({index,found});
      else if(found&&item.outcome==='sat')solverEvidence[index]={...solverEvidence[index],reason:item.reason+'; the counterexample query gave no values ('+found.outcome+')'};
    }
    for(const c of item.induction?.cases??[])
      if(c.outcome==='sat'&&c.values)searched.push({index,found:{outcome:'sat',values:c.values,fingerprint:c.taskFingerprint,runFingerprint:c.runFingerprint},inductionCase:c.case});
  }
  if(searched.length) {
    const checked=await compiler.proofTasks({...request,proofCounterexamples:searched.map(({index,found})=>({
      owner:solverEvidence[index].owner,declaration:solverEvidence[index].declaration,
      taskFingerprint:tasks[index].taskFingerprint,values:found.values}))});
    const checks=checked.counterexampleChecks??[];
    searched.forEach(({index,found,inductionCase},position)=>{
      const item=solverEvidence[index],check=checks[position];
      if(!check||check.owner!==item.owner||check.declaration!==item.declaration||item.status==='refuted')return;
      const counterexample={inputs:check.inputs??[],values:found.values,fingerprint:found.fingerprint,
        runFingerprint:found.runFingerprint,check:check.status};
      if(check.status==='refuted') {
        const shown=(check.inputs??[]).map(input=>input.name+' = '+input.value).join(', ');
        solverEvidence[index]={...item,status:'refuted',modelValidated:true,counterexample,
          reason:(found.runFingerprint?'Z3 found ':'the law has no inputs; ')+(shown?'the input '+shown:'that the law fails')+
            (inductionCase?' in case '+inductionCase+' of the induction':'')+'; the reference evaluator confirms it: '+check.reason};
      } else if(inductionCase&&check.status==='model-not-confirmed') {
        // Why3's SW: the case fails only under its hypothesis, not the law.
        solverEvidence[index]={...item,counterexample,
          reason:item.reason+'; in case '+inductionCase+' the induction hypothesis is too weak: the law holds at Z3\'s input, '+check.reason};
      } else if(check.status==='model-not-confirmed'&&(item.recursion||tasks[index].recursion)) {
        // Unfolding may stop early, so such a model need not be one of the
        // real definitions: incomplete, not a translation error.
        solverEvidence[index]={...item,counterexample,reason:item.reason+'; Z3 gave a model the reference evaluator does not confirm, after unfolding that may have stopped early: '+check.reason};
      } else if(check.status==='model-not-confirmed') {
        solverEvidence[index]={...item,counterexample,reason:'Z3 gave a model the reference evaluator does not confirm: '+check.reason};
        diagnostics.push({code:'proof-translation',message:`Z3's model for ${item.declaration} is not a counterexample: ${check.reason}`,at:item.at});
      } else if(item.outcome==='sat')solverEvidence[index]={...item,counterexample,reason:item.reason+'; '+check.reason};
    });
  }
  // A law proved by induction rests on the laws it cites: while one of them
  // is not proved (or checked on every input), neither is the law.
  const current=new Map();
  for(const row of result.evidence??[])if(row.stage==='law')current.set(row.declaration,row.status);
  for(const item of solverEvidence)if(item.declaration&&!item.kind)current.set(item.declaration,item.status==='proved'?'proved':
    ['proved','exhaustively-checked'].includes(current.get(item.declaration))?current.get(item.declaration):item.status);
  let changed=true;
  while(changed) {
    changed=false;
    solverEvidence.forEach((item,index)=>{
      const cited=item.induction?.using??[];
      if(item.status!=='proved'||!cited.length)return;
      const open=cited.filter(law=>!['proved','exhaustively-checked'].includes(current.get(law)));
      if(!open.length)return;
      solverEvidence[index]={...item,status:'incomplete',reason:item.reason+'; it cites '+
        open.map(law=>law.split('::law::').pop()+', which is '+(current.get(law)??'not proved')).join(', ')};
      current.set(item.declaration,'incomplete');changed=true;
    });
  }
  const evidence=(result.evidence??[]).map(row=>{
    const found=solverEvidence.find(item=>item.owner===row.owner&&item.declaration===row.declaration);
    if(row.stage!=='law'||!found)return row;
    if(found.status!=='proved') {
      if(['proved','exhaustively-checked','known-failing','skipped','flaky'].includes(row.status))return row;
      return {...row,status:found.status==='unsupported'?'unsupported':found.status==='refuted'?'refuted':'incomplete',reason:found.reason};
    }
    if(row.status==='known-failing') {
      diagnostics.push({code:'harness',message:`Z3 proved ${row.declaration}; its harness cannot mark it known failing`,at:found.at});
      return row;
    }
    return {...row,status:'proved',reason:found.reason+`; task ${found.taskFingerprint}`};
  });
  // The law-set checks the compiler left undecided (completeness, overlap,
  // conflict, vacuity): Z3 runs each task, and the compiler confirms every
  // model with its reference evaluator before a check is refuted.
  let settled=evidence,found=diagnostics;
  if(analysis.length) {
    const answers=[],ran=new Map();
    for(const row of analysis) {
      if(row.status!=='ready') {
        solverEvidence.push({owner:row.owner,declaration:row.declaration,stage:row.stage,kind:'analysis',
          encoding:'lawspec-smtlib-v2',status:'unsupported',outcome:'unsupported',reason:row.reason,configuration:config});
        continue;
      }
      for(const task of row.tasks) {
        if(selected.error) {ran.set(task.fingerprint,{row,outcome:selected.outcome,error:selected.error});continue;}
        const input=`(set-option :print-success false)\n(set-option :produce-models true)\n`+
          `(set-option :random-seed ${config.seed})\n(set-option :rlimit ${config.resourceLimit})\n`+task.script+'(check-sat)\n';
        const run=await execute(selected.binary,selected.args,input,config,true,
          token=>token==='sat'&&task.inputs.length?`(get-value (${task.inputs.join(' ')}))\n(exit)\n`:'(exit)\n');
        const outcome=run.timeout?'timeout':run.error||run.exitCode!==0||!run.outcome?'failed':run.outcome;
        const values=outcome==='sat'&&task.inputs.length?run.stdout.slice(run.stdout.indexOf('\n')+1).trim():'';
        ran.set(task.fingerprint,{row,outcome,run,runFingerprint:fingerprint([task.fingerprint,selected.fingerprint,run.input])});
        answers.push({fingerprint:task.fingerprint,outcome,values});
      }
    }
    const checked=answers.length?await compiler.proofTasks({...request,analysisResults:answers}):{};
    const rows=new Map((checked.analysisEvidence??[]).map(row=>[row.declaration+'\u0000'+row.stage,row]));
    settled=evidence.map(row=>rows.get(row.declaration+'\u0000'+row.stage)??row);
    found=[...diagnostics,...(checked.diagnostics??[]).filter(row=>row.code==='refuted')];
    for(const verdict of checked.analysisChecks??[]) {
      const done=ran.get(verdict.fingerprint)??{};
      solverEvidence.push({owner:verdict.owner,declaration:verdict.declaration,stage:verdict.stage,kind:'analysis',
        encoding:'lawspec-smtlib-v2',taskFingerprint:verdict.fingerprint,status:verdict.status,
        outcome:done.outcome??'failed',reason:verdict.reason,check:verdict.check,configuration:config,
        ...(done.run?{prover:{name:'z3',version:selected.version,binary:selected.binary,binaryFingerprint:selected.binaryFingerprint,
          fingerprint:selected.fingerprint,arguments:selected.args},runFingerprint:done.runFingerprint,
          elapsedMs:done.run.elapsedMs,exitCode:done.run.exitCode,stdout:done.run.stdout,stderr:done.run.stderr}:{})});
    }
    for(const [fingerprintOf,done] of ran)if(done.error&&!(checked.analysisChecks??[]).some(v=>v.fingerprint===fingerprintOf))
      solverEvidence.push({kind:'analysis',owner:done.row.owner,declaration:done.row.declaration,stage:done.row.stage,
        taskFingerprint:fingerprintOf,encoding:'lawspec-smtlib-v2',status:'incomplete',
        outcome:done.outcome,reason:done.error,configuration:config});
  }
  return {...result,diagnostics:found,evidence:settled,solverEvidence};
}
