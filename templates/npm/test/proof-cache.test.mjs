import assert from 'node:assert/strict';
import {test} from 'node:test';
import {appendFile,chmod,mkdtemp,readFile,readdir,rm,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {proveWithZ3} from './prove-cli.mjs';

// These tests exercise actual child processes and disk reuse through
// lawspec prove, with a stand-in solver that counts its runs. Until 0.36.0
// they handed the legacy host stub compilers; they now prove real laws.
const law=(name,body,padding='')=>({sources:[{path:'input.lawspec',
  content:`unit reuse\n${padding}law ${name} is definition: ${body} end definition end law\nend unit\n`}]});
const square='for all (n :: Integer) => n * n >= 0 end for all';
const request=(cacheDirectory,source,machineBits)=>({languageProfile:'1.0-rc.2',verification:{layers:['proof']},
  ...(machineBits?{machineBits}:{}),...(cacheDirectory?{cacheDirectory}:{}),...source});

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
    const cache=path.join(folder,'cache');
    const count=async()=>{try{return (await readFile(log,'utf8')).trim().split('\n').length;}catch{return 0;}};
    const first=await proveWithZ3(null,request(cache,law('original',square)),{binary});
    assert.deepEqual(first.diagnostics,[]);
    assert.equal(first.solverEvidence[0].status,'proved');
    assert.equal(await count(),1);
    // Renamed and moved: the same obligation, so the receipt is reused.
    const renamed=await proveWithZ3(null,request(cache,law('renamed',square,'\n\n\n')),{binary});
    assert.equal(await count(),1);
    assert.equal(renamed.solverEvidence[0].status,'proved');
    assert.equal(renamed.solverEvidence[0].declaration,'reuse::law::renamed');
    assert.equal(renamed.solverEvidence[0].at.line,5);
    assert.equal(renamed.solverEvidence[0].runFingerprint,first.solverEvidence[0].runFingerprint);
    assert.equal(renamed.solverEvidence[0].reused.declaration,'reuse::law::original');
    // A corrupted receipt is not reused.
    const [savedName]=await readdir(path.join(cache,'solver-goals-v1'));
    const savedPath=path.join(cache,'solver-goals-v1',savedName);
    const saved=JSON.parse(await readFile(savedPath,'utf8'));
    saved.receipt.stdout='corrupted';
    await writeFile(savedPath,JSON.stringify(saved));
    await proveWithZ3(null,request(cache,law('original',square)),{binary});
    assert.equal(await count(),2);
    // Changed behaviour, solver settings, machine width or executable, or no cache: a new run.
    await proveWithZ3(null,request(cache,law('original','for all (n :: Integer) => n * n + 1 >= 0 end for all')),{binary});
    assert.equal(await count(),3);
    await proveWithZ3(null,request(cache,law('original',square)),{binary,seed:1});
    assert.equal(await count(),4);
    await proveWithZ3(null,request(cache,law('original',square),32),{binary});
    assert.equal(await count(),5);
    await appendFile(binary,'\n// changed solver executable\n');
    await proveWithZ3(null,request(cache,law('original',square)),{binary});
    assert.equal(await count(),6);
    await proveWithZ3(null,request(null,law('original',square)),{binary});
    assert.equal(await count(),7);
    // Mandatory rejection runs no solver.
    const invalid=await proveWithZ3(null,request(cache,{sources:[{path:'input.lawspec',
      content:'unit reuse\nfunction broken (n :: Integer) -> Rational is 1 / 0 end function\nend unit\n'}]}),{binary});
    assert.equal(await count(),7);
    assert.ok(invalid.diagnostics.some(row=>row.code==='total'));
    // The CLI prints a rejected request's diagnostics with no solver evidence at all.
    assert.ok(!invalid.solverEvidence?.length);
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
    const cache=path.join(folder,'cache');
    for(let i=0;i<2;i++) {
      const result=await proveWithZ3(null,request(cache,law('selected',square)),{binary});
      assert.equal(result.solverEvidence[0].status,'incomplete');
      assert.equal(result.solverEvidence[0].outcome,'unknown');
      assert.equal(result.solverEvidence[0].reused,undefined);
      assert.equal(result.evidence.find(row=>row.stage==='law').status,'incomplete');
    }
    // An unknown answer runs the task again for its reason: two runs a call.
    assert.equal((await readFile(log,'utf8')).trim().split('\n').length,4);
    await assert.rejects(readdir(path.join(cache,'solver-goals-v1')),{code:'ENOENT'});
  } finally {await rm(folder,{recursive:true,force:true});}
});

// A cached bounded model whose current replay rejects it is retried: the
// legacy test drove this with a stub compiler's model tasks, which the core
// cannot be handed; Prove.hs analysisQuery keeps the rule (an answer is
// saved only once the compiler settles it).
