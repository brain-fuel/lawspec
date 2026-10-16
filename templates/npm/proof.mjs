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
const encoding='lawspec-smtlib-v1';

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
function execute(binary,args,initial,config,interactive=false) {
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
        const finish=token==='sat'?'(get-model)\n(exit)\n':
          token==='unknown'?'(get-info :reason-unknown)\n(exit)\n':'(exit)\n';
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

async function prover(config) {
  const binary=await executable(config.binary);
  const binaryFingerprint=hash(await readFile(binary));
  const versionRun=await execute(binary,['-version'],'',config);
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
  return task.encoding===encoding&&[32,64].includes(task.machineBits)&&
    ['owner','declaration','programFingerprint','script','taskFingerprint'].every(key=>typeof task[key]==='string')&&
    /^[0-9a-f]{64}$/.test(task.programFingerprint)&&
    proofTaskFingerprint(task)===task.taskFingerprint;
}

async function solve(task,selected,config) {
  const common={owner:task.owner,declaration:task.declaration,at:task.at,
    programFingerprint:task.programFingerprint,taskFingerprint:task.taskFingerprint,
    encoding:task.encoding,machineBits:task.machineBits,configuration:config};
  if(task.status==='unsupported')return {...common,status:'unsupported',outcome:'unsupported',reason:task.reason};
  if(task.status!=='ready'||!validTask(task))
    return {...common,status:'incomplete',outcome:'failed',reason:'Compiler proof task binding is invalid'};
  if(selected.error)return {...common,status:'incomplete',outcome:selected.outcome,reason:selected.error};
  const input=`(set-option :print-success false)\n(set-option :produce-models true)\n`+
    `(set-option :random-seed ${config.seed})\n(set-option :rlimit ${config.resourceLimit})\n`+
    task.script+'(check-sat)\n';
  const run=await execute(selected.binary,selected.args,input,config,true);
  let unchanged=false;
  try {unchanged=hash(await readFile(selected.binary))===selected.binaryFingerprint;} catch {}
  const metadata={...common,prover:{name:'z3',version:selected.version,
    binary:selected.binary,binaryFingerprint:selected.binaryFingerprint,
    fingerprint:selected.fingerprint,arguments:selected.args},configuration:config,
    runFingerprint:fingerprint([task.taskFingerprint,selected.fingerprint,run.input]),
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
  return {...metadata,status:outcome==='unsat'?'proved':'incomplete',outcome,reason,
    ...(run.outcome==='sat'?{model:run.stdout.slice(run.stdout.indexOf('\n')+1).trim(),modelValidated:false}:{})};
}

// Tasks always come freshly from the compiler for the supplied source request.
// An imported JSON solver report cannot upgrade a law's evidence through here.
export async function proveWithZ3(compiler,request,options={}) {
  const config=optionsWithDefaults(options);
  const result=await compiler.proofTasks(request);
  if(result.diagnostics?.length)return {...result,solverEvidence:[]};
  const tasks=result.proofTasks??[];
  let selected={};
  if(tasks.some(task=>task.status==='ready')) {
    try {selected=await prover(config);}
    catch(error){selected={error:error.message,outcome:error.code==='ENOENT'?'unavailable':error.outcome??'failed'};}
  }
  const solverEvidence=[];
  for(const task of tasks)solverEvidence.push(await solve(task,selected,config));
  const diagnostics=[...(result.diagnostics??[])];
  const evidence=(result.evidence??[]).map(row=>{
    const found=solverEvidence.find(item=>item.owner===row.owner&&item.declaration===row.declaration);
    if(row.stage!=='law'||!found)return row;
    if(found.status!=='proved') {
      if(['proved','exhaustively-checked','known-failing','skipped','flaky'].includes(row.status))return row;
      return {...row,status:found.status==='unsupported'?'unsupported':'incomplete',reason:found.reason};
    }
    if(row.status==='known-failing') {
      diagnostics.push({code:'harness',message:`Z3 proved ${row.declaration}; its harness cannot mark it known failing`,at:found.at});
      return row;
    }
    return {...row,status:'proved',reason:found.reason+`; task ${found.taskFingerprint}`};
  });
  return {...result,diagnostics,evidence,solverEvidence};
}
