import assert from 'node:assert/strict';
import {test} from 'node:test';
import {appendFile,chmod,mkdtemp,readFile,readdir,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {proveWithZ3,proofTaskFingerprint} from '../proof.mjs';

// These tests exercise actual child processes and disk reuse. The compiler
// stub supplies admitted tasks; compiler identity invariance has its own
// native/WASM integration test. The stub counts admission on every call.
test('semantic proof reuse preserves the original execution and invalidates on solver settings and behaviour',async()=>{
  const folder=await mkdtemp(path.join(tmpdir(),'lawspec-proof-reuse-'));
  try {
    const binary=path.join(folder,'solver');
    const log=path.join(folder,'executions');
    const source=`#!/usr/bin/env node
const fs=require('node:fs');
if(process.argv.includes('-version')){console.log('Z3 version 0.0.0 - cache protocol test');process.exit(0);}
fs.appendFileSync(${JSON.stringify(log)},'task\\n');
let text='',answered=false;
process.stdin.on('data',chunk=>{text+=chunk;if(!answered&&text.includes('(check-sat)')){answered=true;process.stdout.write('unsat\\n');}});
process.stdin.on('end',()=>process.exit(0));
`;
    await writeFile(binary,source);await chmod(binary,0o755);
    let admissions=0;
    const compiler={proofTasks:async request=>{
      admissions++;
      if(request.invalid)return {diagnostics:[{code:'total',message:'mandatory rejection'}]};
      const task={status:'ready',encoding:'lawspec-smtlib-v2',lawFingerprint:(request.changed?'b':'a').repeat(64),
        machineBits:request.machineBits??64,owner:'reuse',declaration:request.renamed?'reuse::renamed':'reuse::original',
        at:{file:'input.lawspec',line:request.moved?10:1,column:1},script:request.renamed?'; renamed\n(assert false)\n':'(assert false)\n'};
      task.taskFingerprint=proofTaskFingerprint(task);
      return {diagnostics:[],proofTasks:[task],evidence:[{owner:task.owner,declaration:task.declaration,stage:'law',status:'planned'}]};
    }};
    const input={cacheDirectory:path.join(folder,'cache')};
    const count=async()=>{try{return (await readFile(log,'utf8')).trim().split('\n').length;}catch{return 0;}};
    const first=await proveWithZ3(compiler,input,{binary});
    assert.equal(await count(),1);
    const renamed=await proveWithZ3(compiler,{...input,renamed:true,moved:true},{binary});
    assert.equal(await count(),1);
    assert.equal(admissions,2);
    assert.equal(renamed.solverEvidence[0].status,'proved');
    assert.equal(renamed.solverEvidence[0].declaration,'reuse::renamed');
    assert.equal(renamed.solverEvidence[0].at.line,10);
    assert.equal(renamed.solverEvidence[0].taskFingerprint,first.solverEvidence[0].taskFingerprint);
    assert.equal(renamed.solverEvidence[0].runFingerprint,first.solverEvidence[0].runFingerprint);
    assert.equal(renamed.solverEvidence[0].reused.declaration,'reuse::original');
    assert.notEqual(renamed.solverEvidence[0].currentTaskFingerprint,first.solverEvidence[0].taskFingerprint);
    const [savedName]=await readdir(path.join(folder,'cache','solver-goals-v1'));
    const savedPath=path.join(folder,'cache','solver-goals-v1',savedName);
    const saved=JSON.parse(await readFile(savedPath,'utf8'));
    saved.receipt.stdout='corrupted';
    await writeFile(savedPath,JSON.stringify(saved));
    await proveWithZ3(compiler,input,{binary});
    assert.equal(await count(),2);
    await proveWithZ3(compiler,{...input,changed:true},{binary});
    assert.equal(await count(),3);
    await proveWithZ3(compiler,input,{binary,seed:1});
    assert.equal(await count(),4);
    await proveWithZ3(compiler,{...input,machineBits:32},{binary});
    assert.equal(await count(),5);
    await appendFile(binary,'\n// changed solver executable\n');
    await proveWithZ3(compiler,input,{binary});
    assert.equal(await count(),6);
    await proveWithZ3(compiler,{}, {binary});
    assert.equal(await count(),7);
    const invalid=await proveWithZ3(compiler,{...input,invalid:true},{binary});
    assert.equal(await count(),7);
    assert.equal(invalid.diagnostics[0].code,'total');
    assert.deepEqual(invalid.solverEvidence,[]);
  } finally {await rm(folder,{recursive:true,force:true});}
});

test('unknown solver results are never persisted or promoted by receipt reuse',async()=>{
  const folder=await mkdtemp(path.join(tmpdir(),'lawspec-proof-unknown-'));
  try {
    const binary=path.join(folder,'solver');
    const log=path.join(folder,'executions');
    await writeFile(binary,`#!/usr/bin/env node
const fs=require('node:fs');
if(process.argv.includes('-version')){console.log('Z3 version 0.0.0 - cache protocol test');process.exit(0);}
fs.appendFileSync(${JSON.stringify(log)},'task\\n');
let input='',answered=false;
process.stdin.on('data',chunk=>{input+=chunk;if(!answered&&input.includes('(check-sat)')){answered=true;process.stdout.write('unknown\\n(:reason-unknown "incomplete")\\n');}});
process.stdin.on('end',()=>process.exit(0));
`);await chmod(binary,0o755);
    const task={status:'ready',encoding:'lawspec-smtlib-v2',lawFingerprint:'a'.repeat(64),machineBits:64,
      owner:'unknown',declaration:'unknown::selected',at:{file:'input.lawspec',line:1,column:1},script:'(assert true)\n'};
    task.taskFingerprint=proofTaskFingerprint(task);
    const compiler={proofTasks:async()=>({diagnostics:[],proofTasks:[task],evidence:[
      {owner:task.owner,declaration:task.declaration,stage:'law',status:'planned'}]})};
    const input={cacheDirectory:path.join(folder,'cache')};
    for(let i=0;i<2;i++) {
      const result=await proveWithZ3(compiler,input,{binary});
      assert.equal(result.solverEvidence[0].status,'incomplete');
      assert.equal(result.solverEvidence[0].outcome,'unknown');
      assert.equal(result.solverEvidence[0].reused,undefined);
      assert.equal(result.evidence[0].status,'incomplete');
    }
    assert.equal((await readFile(log,'utf8')).trim().split('\n').length,2);
    await assert.rejects(readdir(path.join(folder,'cache','solver-goals-v1')),{code:'ENOENT'});
  } finally {await rm(folder,{recursive:true,force:true});}
});
