import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {fingerprintInputs} from '../input-files.mjs';
import {projectDigest} from '../test-command.mjs';

test('Clojure classpath caches do not stale inputs while dependency and provider edits do',async t=>{
  const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-clojure-inputs-'));
  t.after(()=>rm(root,{recursive:true,force:true}));
  const dependency=path.join(root,'deps.edn'),provider=path.join(root,'src','provider.clj');
  const deps='{:paths ["src"] :deps {org.clojure/clojure {:mvn/version "1.12.5"}}}';
  const implementation='(ns provider)\n(defn read-value [] 7)\n';
  await mkdir(path.dirname(provider));
  await writeFile(dependency,deps);await writeFile(provider,implementation);
  const snapshot=()=>Promise.all([
    projectDigest(root,new Set(),'clojure'),fingerprintInputs(root,['.'])]);
  const before=await snapshot();
  await mkdir(path.join(root,'.cpcache'));
  // Doctor asks for the :test basis; the native launcher also creates the
  // default basis. These are results of dependency resolution, not sources.
  for(const name of ['test.basis','test.cp','test.main','default.basis','default.cp'])
    await writeFile(path.join(root,'.cpcache',name),'resolved classpath '+name);
  assert.deepEqual(await snapshot(),before);
  await writeFile(path.join(root,'.cpcache','default.cp'),'rebuilt absolute classpath');
  assert.deepEqual(await snapshot(),before);
  await writeFile(dependency,deps.replace('1.12.5','1.12.4'));
  const changedDependencies=await snapshot();
  changedDependencies.forEach((value,index)=>assert.notDeepEqual(value,before[index]));
  await writeFile(dependency,deps);assert.deepEqual(await snapshot(),before);
  await writeFile(provider,implementation.replace('7','8'));
  const changedProvider=await snapshot();
  changedProvider.forEach((value,index)=>assert.notDeepEqual(value,before[index]));
  await writeFile(provider,implementation);assert.deepEqual(await snapshot(),before);
  // Excluding the generated directory does not exclude arbitrary basis files.
  await writeFile(path.join(root,'provider.basis'),'a real declared input');
  const changedOther=await snapshot();
  changedOther.forEach((value,index)=>assert.notDeepEqual(value,before[index]));
});
