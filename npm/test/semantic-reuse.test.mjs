// Generated from templates/npm/test/semantic-reuse.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFile,spawnSync} from 'node:child_process';
import {promisify} from 'node:util';
import {chmod,mkdir,mkdtemp,readFile,rm,symlink,writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createCompiler} from '../api.mjs';
import {proveWithZ3} from '../proof.mjs';
import {templates} from '../templates.mjs';

const exec=promisify(execFile);
const cli=fileURLToPath(new URL('../bin/lawspec.mjs',import.meta.url));
const base=`unit identity.reuse
function twice (value :: Integer where value >= -3 && value <= 3) -> Integer is value + value end function
function unrelated (value :: Integer) -> Integer is value + 1 end function
law selected is
  description: "Twice adds the input to itself." end description
  definition: for all (input :: Integer where input >= -3 && input <= 3) => twice input = input * 2 end for all end definition
end law
end unit
`;
const harmless=[
  base.replaceAll('value','number').split('\n').join('\n\n'),
  base.replace('Twice adds the input to itself.','Twice doubles its input.'),
  base.replace('is value + 1 end function','is value + 2 end function'),
  base.replaceAll('twice','double'),
  base.replace('law selected','law "|renamed law|'),
];
const count=async filename=>{try{return (await readFile(filename,'utf8')).trim().split('\n').filter(Boolean).length;}catch{return 0;}};

test('real native tests rerun zero cases after harmless source edits and rerun a changed dependency',async()=>{
  const folder=await mkdtemp(path.join(tmpdir(),'lawspec-native-semantic-'));
  try {
    const project=path.join(folder,'app');await mkdir(project);
    for(const [file,content] of Object.entries(templates('javascript'))) {
      await mkdir(path.dirname(path.join(project,file)),{recursive:true});
      await writeFile(path.join(project,file),content);
    }
    const modules=fileURLToPath(new URL('../../.integration/javascript/node_modules',import.meta.url));
    await symlink(modules,path.join(project,'node_modules'),'dir');
    const log=path.join(folder,'native-runs');
    const preload=path.join(folder,'observe.mjs');
    await writeFile(preload,`import {appendFileSync} from 'node:fs';\nif(process.env.LAWSPEC_NODE_RUN)appendFileSync(${JSON.stringify(log)},'native\\n');\n`);
    await writeFile(path.join(folder,'lawspec.json'),JSON.stringify({version:2,languageProfile:'1.0-rc.2',
      sources:['input.lawspec'],verification:{layers:['property','examples']},targets:[{language:'javascript',root:'app'}]}));
    const run=async (command,args=[])=>exec(process.execPath,[cli,command,'--json',...args],{cwd:folder,
      env:{...process.env,NODE_OPTIONS:`--import=${preload}`},maxBuffer:4*1024*1024});
    const generate=async content=>{await writeFile(path.join(folder,'input.lawspec'),content);await run('generate');};
    await generate(base);
    const first=JSON.parse((await run('test')).stdout);
    assert.ok(first[0].ran.length>0);
    const original=await count(log);assert.ok(original>0);
    for(const content of harmless) {
      await generate(content);
      const result=JSON.parse((await run('test')).stdout);
      assert.deepEqual(result[0].ran,[]);
      assert.equal(result[0].unchanged,1);
      assert.equal(await count(log),original);
    }
    const report=JSON.parse((await run('evidence')).stdout);
    const native=(Array.isArray(report)?report:report.evidence).find(row=>row.stage==='law')?.nativeEvidence;
    assert.equal(native?.status,'passed');
    assert.ok(native.observations.some(row=>row.reused));
    assert.equal(await count(log),original);
    // The same semantic run also survives the other compiler-owned layout.
    await writeFile(path.join(folder,'input.lawspec'),base);
    for(const [file,content] of Object.entries(templates('javascript',{minify:true})))
      await writeFile(path.join(project,file),content);
    await run('generate',['--minify']);
    const compact=JSON.parse((await run('test',['--minify'])).stdout);
    assert.deepEqual(compact[0].ran,[]);
    assert.equal(await count(log),original);
    // A fresh request must always observe a real invocation.
    const fresh=JSON.parse((await run('test',['--minify','--fresh'])).stdout);
    assert.ok(fresh[0].ran.length>0);
    assert.ok(await count(log)>original);
    const beforeChanged=await count(log);
    await generate(base.replace('is value + value end function','is value + value + 1 end function'));
    await assert.rejects(run('test'));
    assert.ok(await count(log)>beforeChanged);
  } finally {await rm(folder,{recursive:true,force:true});}
});

const z3=process.env.LAWSPEC_Z3??(spawnSync('z3',['-version'],{encoding:'utf8'}).status===0?'z3':null);
test('real solver receipts survive harmless source edits with zero new solver tasks',
  {skip:z3?false:'install Z3 or set LAWSPEC_Z3 for semantic receipt integration'},async()=>{
    const folder=await mkdtemp(path.join(tmpdir(),'lawspec-solver-semantic-'));
    try {
      const log=path.join(folder,'solver-runs');
      const binary=path.join(folder,'solver');
      await writeFile(binary,`#!/usr/bin/env node
const fs=require('node:fs');
const {spawn}=require('node:child_process');
if(!process.argv.includes('-version'))fs.appendFileSync(${JSON.stringify(log)},'solver\\n');
const child=spawn(${JSON.stringify(z3)},process.argv.slice(2),{stdio:'inherit'});
child.on('error',()=>process.exit(127));
child.on('exit',(code,signal)=>{if(signal)process.kill(process.pid,signal);else process.exit(code??1);});
`);await chmod(binary,0o755);
      const compiler=await createCompiler();
      const request=content=>({schemaVersion:5,languageProfile:'1.0-rc.2',machineBits:64,
        verification:{layers:['proof']},cacheDirectory:path.join(folder,'cache'),
        sources:[{path:'input.lawspec',content}]});
      const first=await proveWithZ3(compiler,request(base),{binary});
      assert.deepEqual(first.diagnostics,[]);
      assert.equal(first.solverEvidence[0].status,'proved');
      const original=await count(log);assert.ok(original>0);
      for(const content of harmless) {
        const result=await proveWithZ3(compiler,request(content),{binary});
        assert.deepEqual(result.diagnostics,[]);
        assert.equal(result.solverEvidence[0].status,'proved');
        assert.equal(result.solverEvidence[0].declaration,result.proofTasks[0].declaration);
        assert.equal(result.evidence.find(row=>row.stage==='law'&&row.declaration===result.proofTasks[0].declaration)?.status,'proved');
        assert.ok(result.solverEvidence[0].reused);
        assert.equal(result.solverEvidence[0].runFingerprint,first.solverEvidence[0].runFingerprint);
        assert.equal(await count(log),original);
      }
      const changed=await proveWithZ3(compiler,request(base.replace('is value + value end function','is value + value + 1 end function')),{binary});
      assert.equal(changed.solverEvidence[0].status,'refuted');
      assert.equal(changed.solverEvidence[0].modelValidated,true);
      assert.ok(await count(log)>original);
    } finally {await rm(folder,{recursive:true,force:true});}
  });
