import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,mkdir,writeFile,readFile,rm,symlink} from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {captureScalaBuildFailure,isScalaCompilationFailure} from '../scala-build-state.mjs';

test('Scala failure snapshots retain actual ownership and outputs without rewriting them',async()=>{
  const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-scala-state-'));
  try {
    const config=path.join(root,'.scala-build','.bloop');
    const classes=path.join(root,'.scala-build','project','classes','main');
    await mkdir(config,{recursive:true});await mkdir(classes,{recursive:true});
    const project={name:'same-display-name',directory:config,workspaceDir:root,classesDir:classes,
      sources:[path.join(root,'Stock.scala')],classpath:['dependency.jar']};
    await writeFile(path.join(config,'project.json'),JSON.stringify({project}));
    await writeFile(path.join(config,'broken.json'),'not json');
    await writeFile(path.join(classes,'Stock.class'),'class bytes');
    await writeFile(path.join(classes,'Stock.tasty'),'tasty bytes');
    await symlink(root,path.join(classes,'loop'));
    const output='Compiled project\n\u001b[31m[error] NativeCalls.java:9\n[error] package warehouse.Stock does not exist\nError compiling project';
    assert.equal(isScalaCompilationFailure(output),true);
    assert.equal(isScalaCompilationFailure('a law was refuted at runtime'),false);
    const directory=await captureScalaBuildFailure({root,command:'/tool/scala',args:['test','.'],output,phase:'correct'});
    assert.ok(directory);
    const state=JSON.parse(await readFile(path.join(directory,'state.json'),'utf8'));
    assert.equal(state.phase,'correct');assert.equal(state.command,'/tool/scala');
    assert.deepEqual(state.args,['test','.']);
    assert.deepEqual(state.configurations,[{file:'.scala-build/.bloop/project.json',...project}]);
    assert.equal(state.inventory.filter(file=>file.path.endsWith('.class')).length,1);
    assert.equal(state.inventory.filter(file=>file.path.endsWith('.tasty')).length,1);
    assert.equal(state.inventory.filter(file=>file.kind==='symlink').length,1);
    assert.match(state.firstCompilerError.join('\n'),/package warehouse.Stock/);
    assert.deepEqual(state.errors,[{path:'.scala-build/.bloop/broken.json',code:'invalid-json'}]);
    assert.equal(await readFile(path.join(directory,'compiler.log'),'utf8'),output);
    assert.deepEqual(JSON.parse(await readFile(path.join(directory,'project.json'),'utf8')),{project});
    assert.equal(await readFile(path.join(classes,'Stock.class'),'utf8'),'class bytes');
    assert.equal(await readFile(path.join(classes,'Stock.tasty'),'utf8'),'tasty bytes');
    const again=await captureScalaBuildFailure({root,command:'scala',args:[],output});
    assert.notEqual(directory,again);
  }finally{await rm(root,{recursive:true,force:true});}
});

test('missing Scala state or a failed snapshot cannot turn a compiler failure into success',async()=>{
  const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-scala-empty-'));
  try{
    const directory=await captureScalaBuildFailure({root,command:'scala',args:['test','.'],output:'Compilation failed'});
    const state=JSON.parse(await readFile(path.join(directory,'state.json'),'utf8'));
    assert.deepEqual(state.configurations,[]);assert.deepEqual(state.inventory,[]);
    assert.equal(await captureScalaBuildFailure({root:path.join(root,'absent'),command:'scala',args:[],output:''}),null);
  }finally{await rm(root,{recursive:true,force:true});}
});
