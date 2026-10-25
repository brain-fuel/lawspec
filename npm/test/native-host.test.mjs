// Generated from templates/npm/test/native-host.test.mjs by lawspec-dev generate. Do not edit.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {fingerprintNativeHost} from '../native-host.mjs';

test('native host identity binds installed transitive implementation and separates proof/presentation output',async t=>{
  const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-native-host-'));
  t.after(()=>rm(root,{recursive:true,force:true}));
  await mkdir(path.join(root,'bin'));
  await writeFile(path.join(root,'package.json'),JSON.stringify({name:'sdk-fixture',version:'1',dependencies:{adapter:'1'}}));
  await writeFile(path.join(root,'bin/lawspec.mjs'),'export const runner=1;');
  await writeFile(path.join(root,'test-command.mjs'),'export const selection=1;');
  await writeFile(path.join(root,'proof.mjs'),'export const optionalProof=1;');
  for(const[name,dependencies]of [['adapter',{nested:'1'}],['nested',{}]]){
    const folder=path.join(root,'node_modules',name);await mkdir(folder,{recursive:true});
    await writeFile(path.join(folder,'package.json'),JSON.stringify({name,version:'1',main:'index.js',dependencies}));
    await writeFile(path.join(folder,'index.js'),'module.exports=1;');
  }
  const before=await fingerprintNativeHost(root);
  await mkdir(path.join(root,'generated'));
  await writeFile(path.join(root,'generated/test.mjs'),'changed generated source');
  await writeFile(path.join(root,'README.md'),'changed documentation');
  await writeFile(path.join(root,'core.wasm'),'changed compiler bytes, keyed independently');
  await writeFile(path.join(root,'proof.mjs'),'export const optionalProof=2;');
  assert.equal(await fingerprintNativeHost(root),before);
  await writeFile(path.join(root,'node_modules/nested/index.js'),'module.exports=2;');
  const transitive=await fingerprintNativeHost(root);assert.notEqual(transitive,before);
  await writeFile(path.join(root,'test-command.mjs'),'export const selection=2;');
  assert.notEqual(await fingerprintNativeHost(root),transitive);
});
