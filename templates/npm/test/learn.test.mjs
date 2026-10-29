import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mkdtemp,readFile,readdir,rm} from 'node:fs/promises';
import {spawn} from 'node:child_process';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {once} from 'node:events';
import {createHash} from 'node:crypto';
import {gunzipSync} from 'node:zlib';
import {serveLearn,packageLearn} from '../learn.mjs';
import {createCompiler} from '../api.mjs';
const course=JSON.parse(await readFile(new URL('../learn/curriculum.json',import.meta.url)));
test('Learn packages the identical local artifact and correct script/WASM MIME types',async()=>{
 const destination=await mkdtemp(path.join(tmpdir(),'lawspec-learn-'));const server=await serveLearn(0,{quiet:true});
 const base=`http://127.0.0.1:${server.address().port}`;
 try{
  await packageLearn(destination);
  const files=[];async function walk(dir,prefix=''){for(const entry of await readdir(dir,{withFileTypes:true})){const name=prefix+entry.name;if(entry.isDirectory())await walk(path.join(dir,entry.name),name+'/');else files.push(name);}}await walk(destination);
  for(const name of files){
   const response=await fetch(base+'/'+name);assert.equal(response.status,200,name);
   if(/\.m?js$/.test(name))assert.match(response.headers.get('content-type'),/^text\/javascript\b/,name);
   if(name.endsWith('.wasm'))assert.equal(response.headers.get('content-type'),'application/wasm');
   if(name.endsWith('.woff2'))assert.equal(response.headers.get('content-type'),'font/woff2');
   const served=new Uint8Array(await response.arrayBuffer());assert.deepEqual(served,new Uint8Array(await readFile(path.join(destination,name))),name);
  }
  const manifest=JSON.parse(await readFile(path.join(destination,'vendor/manifest.json')));
  for(const [name,expected] of Object.entries(manifest.assets))assert.equal(createHash('sha256').update(await readFile(path.join(destination,'vendor',name))).digest('hex'),expected.sha256,name);
  assert.deepEqual(gunzipSync(await readFile(path.join(destination,'core.wasm.gz'))),await readFile(new URL('../core.wasm',import.meta.url)));
  assert.equal((await fetch(base+'/%2e%2e%2fpackage.json')).status,404);
  assert.equal((await fetch(base+'/',{method:'POST',body:'source'})).status,405);
 }finally{await new Promise(resolve=>server.close(resolve));await rm(destination,{recursive:true,force:true});}
});
test('all lesson definitions validate without selecting optional verification',async()=>{
 const compiler=await createCompiler();
 for(const lesson of course.lessons){
  const result=await compiler.check({languageProfile:'1.0-rc.2',verification:{layers:[]},sources:Object.entries(lesson.projects.fsharp).filter(([path])=>path.endsWith('.lawspec')).map(([path,content])=>({path,content}))});
  assert.deepEqual(result.diagnostics,[]);assert.equal(result.verification.intrinsicDefinitionChecks,true);assert.equal(result.verification.selection,'no-selected-checks');
 }
});
test('coverage keeps all targets visible and every unimplemented example deferred',async()=>{
 const inventory=JSON.parse(await readFile(new URL('../learn/coverage.json',import.meta.url)));
 for(const name of ['fsharp','typescript','javascript','rust','folio','hcl','yaml','antlr4','make'])assert.ok(inventory.entries.some(row=>row.kind==='target'&&row.name===name));
 for(const name of ['sameItems','sortedSetOf','bind','length','range'])assert.ok(inventory.entries.some(row=>row.kind==='prelude'&&row.name===name));
 assert.ok(inventory.entries.every(row=>row.exampleStatus==='deferred'&&row.checkedExample===null));
 assert.equal(inventory.entries.find(row=>row.name==='folio'&&row.kind==='target').execution,'documentary');
});
test('learn CLI starts outside any project and binds loopback',async()=>{
 const child=spawn(process.execPath,[new URL('../bin/lawspec.mjs',import.meta.url).pathname,'learn','--port','0'],{cwd:tmpdir(),stdio:['ignore','pipe','pipe']});
 try{const[data]=await once(child.stdout,'data');assert.match(String(data),/127\.0\.0\.1:\d+/);}finally{child.kill();await once(child,'exit');}
});
