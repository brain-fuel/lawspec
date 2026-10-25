import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,rm,symlink} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {fingerprintInputs,buildDirectories} from '../input-files.mjs';
import {projectDigest,lawKeys} from '../test-command.mjs';
import {templates} from '../templates.mjs';

test('declared sibling inputs stale only native law keys and ignore build output and owned generated files',async t=>{
  const parent=await mkdtemp(path.join(os.tmpdir(),'lawspec-sibling-inputs-'));
  t.after(()=>rm(parent,{recursive:true,force:true}));
  const component=path.join(parent,'component'),root=path.join(parent,'native'),server=path.join(parent,'server');
  await Promise.all([mkdir(component),mkdir(root),mkdir(server)]);
  await writeFile(path.join(root,'adapter.mjs'),'export const read=()=>7;\n');
  await writeFile(path.join(root,'generated.mjs'),'compiler output\n');
  await writeFile(path.join(server,'implementation.fs'),'module Server\nlet read () = 7\n');
  const generated=new Set(['generated.mjs']),options={inputRoot:component,inputs:['../server','../native']};
  const tests=[{law:'pure',file:'test.mjs',key:'pure-key',callsAdapters:false},
    {law:'native',file:'test.mjs',key:'native-key',callsAdapters:true}];
  const keys=async()=>lawKeys({build:'build',target:{language:'javascript'},machineBits:64,minify:false,
    tests,files:[],environment:'environment',project:await projectDigest(root,generated,'javascript',options)});
  const before=await keys();
  for(const folder of buildDirectories){
    await mkdir(path.join(server,folder));
    await writeFile(path.join(server,folder,'output'),'generated build output');
  }
  await writeFile(path.join(root,'generated.mjs'),'updated compiler output\n');
  assert.deepEqual(await keys(),before);
  const rows=await fingerprintInputs(component,options.inputs,{generated:new Set([path.join(root,'generated.mjs')])});
  assert.deepEqual(rows,await fingerprintInputs(component,[...options.inputs].reverse(),{generated:new Set([path.join(root,'generated.mjs')])}));
  await writeFile(path.join(server,'implementation.fs'),'module Server\nlet read () = 8\n');
  const changed=await keys();
  assert.equal(changed.get('pure'),before.get('pure'));
  assert.notEqual(changed.get('native'),before.get('native'));
});

test('declared inputs retain meaningful generated source and reject symbolic links',async t=>{
  const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-input-paths-'));
  t.after(()=>rm(root,{recursive:true,force:true}));
  await writeFile(path.join(root,'generated.fs'),'native generated source version one');
  const before=await fingerprintInputs(root,['generated.fs']);
  await writeFile(path.join(root,'generated.fs'),'native generated source version two');
  assert.notDeepEqual(await fingerprintInputs(root,['generated.fs']),before);
  await symlink('generated.fs',path.join(root,'alias.fs'));
  await assert.rejects(fingerprintInputs(root,['alias.fs']),/Symbolic links/);
});


test('declared target inputs preserve exact compiler scaffold layout equivalence',async t=>{
  const parent=await mkdtemp(path.join(os.tmpdir(),'lawspec-input-layout-'));
  t.after(()=>rm(parent,{recursive:true,force:true}));
  const component=path.join(parent,'component'),root=path.join(parent,'native');
  await Promise.all([mkdir(component),mkdir(root)]);
  const options={inputRoot:component,inputs:['../native']};
  const write=async minify=>{for(const [file,content] of Object.entries(templates('javascript',{minify}))){
    await mkdir(path.dirname(path.join(root,file)),{recursive:true});await writeFile(path.join(root,file),content);
  }};
  await write(false);const before=await projectDigest(root,new Set(),'javascript',options);
  await write(true);assert.equal(await projectDigest(root,new Set(),'javascript',options),before);
  await writeFile(path.join(root,'package.json'),'{"nativeUserEdit":true}\n');
  assert.notEqual(await projectDigest(root,new Set(),'javascript',options),before);
});
