import assert from 'node:assert/strict';
import {test} from 'node:test';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp,readFile,writeFile,rm,symlink} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createCompiler} from '../api.mjs';
import {planWrites,applyWrites} from '../files.mjs';
import {targets} from '../templates.mjs';
const exec=promisify(execFile);
const cli=new URL('../bin/lawspec.mjs',import.meta.url).pathname;

test('native payment exports cover all targets and preserve application and generated files independently',async()=>{
  const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-native-examples-'));
  const run=(args=[])=>exec(process.execPath,[cli,'examples','--example','payments','--json',...args],{cwd:root});
  try {
    const projects=JSON.parse((await run(['--machine-bits','32'])).stdout);
    assert.deepEqual(projects.map(project=>project.target),targets);
    const compiler=await createCompiler();
    for(const project of projects) {
      assert.ok(project.files.every(file=>file.ownership==='user'));
      const config=JSON.parse(await readFile(path.join(project.directory,'lawspec.json'),'utf8'));
      assert.equal(config.machineBits,32);
      assert.equal(config.targets[0].language,project.target);
      assert.ok(config.targets[0].nativeBindings.generators.length);
      await exec(process.execPath,[cli,'check'],{cwd:project.directory});
      const result=await compiler.planGeneration({target:project.target,machineBits:32,
        sources:[{path:'laws/payments.lawspec',content:await readFile(path.join(project.directory,'laws/payments.lawspec'),'utf8')}],
        nativeBindings:config.targets[0].nativeBindings});
      assert.deepEqual(result.diagnostics,[]);
      assert.ok(result.files.some(file=>file.ownership==='generated' && file.placement==='source'));
      assert.ok(!result.files.some(file=>file.ownership==='user'),'all adapters must be bound');
      await applyWrites([await planWrites(project.directory,result.files)]);
      project.generated=path.join(project.directory,result.files.find(file=>file.ownership==='generated').path);
      await writeFile(project.generated,'edited generated output\n');
      await writeFile(path.join(project.directory,'README.md'),'application documentation\n');
    }
    const again=JSON.parse((await run(['--machine-bits','32'])).stdout);
    assert.ok(again.every(project=>project.changes===0));
    for(const project of projects) {
      assert.equal(await readFile(project.generated,'utf8'),'edited generated output\n');
      assert.equal(await readFile(path.join(project.directory,'README.md'),'utf8'),'application documentation\n');
      const manifest=JSON.parse(await readFile(path.join(project.directory,'.lawspec/generated.json'),'utf8'));
      assert.ok(Object.keys(manifest.files).length);
    }
    const changed=JSON.parse((await run(['--machine-bits','64'])).stdout);
    assert.ok(changed.every(project=>project.adapterUpdates.some(update=>update.path==='lawspec.json')));
    const rust=JSON.parse((await run(['--target','rust','--output','custom','--minify'])).stdout);
    assert.equal(rust.length,1);
    const config=await readFile(path.join(root,'custom/rust/lawspec.json'),'utf8');
    assert.equal(config.trim().split('\n').length,1);
    await assert.rejects(run(['--output','../escape']));
    await symlink(root,path.join(root,'linked'));
    await assert.rejects(run(['--output','linked']));
    await assert.rejects(exec(process.execPath,[cli,'examples','--example','unknown'],{cwd:root}),/Unknown example/);
    await assert.rejects(exec(process.execPath,[cli,'check','--example','payments'],{cwd:root}),/only supported by examples/);
  } finally {await rm(root,{recursive:true,force:true});}
});
