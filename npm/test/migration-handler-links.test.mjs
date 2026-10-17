// Generated from templates/npm/test/migration-handler-links.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createCompiler} from '../api.mjs';
import {migrationReport} from '../migrate.mjs';
import {targets} from '../templates.mjs';
import {writeMigration} from '../migration-write.mjs';
import {mkdtemp,writeFile,readFile,rm} from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';

const compiler=await createCompiler();
const options={schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]}};
const declarations='unit signals\nability Signal is signal :: Bool -> Bool end\n'+
  'handler remembering for Signal with state previous :: Bool start false is '+
  'signal value is ~previous := !previous && value; previous end end\n'+
  'handler other for Signal with state previous :: Bool start false is '+
  'signal value is ~previous := !previous && value; previous end end\n';
const content=declarations+'law `twice` using remembering is '+
  'definition is (signal true; signal true) = false end description is "twice" end end\n';
const sources=[{path:'signals.lawspec',content}];

test('handler law links validate across every configured target without verifying law truth',async()=>{
  for(const machineBits of [32,64]){
    const report=await migrationReport(compiler,{version:1,targets:targets.map(language=>({language,root:language}))},{sources,machineBits});
    assert.deepEqual(report.diagnostics,[]);
    assert.equal(report.validated,true,JSON.stringify(report.blockers));
    assert.equal(report.correspondence.sourceTemplates.status,'matched');
    assert.equal(report.correspondence.targetGeneration.configurationCount,targets.length);
    assert.equal(report.correspondence.nativeBoundary.status,'matched');
    const made=report.sourcePreview.sources.map(({path,content})=>({path,content}));
    assert.match(made[0].content,/law "\|twice\| using remembering/);
    assert.match(made[0].content,/"twice"/);
    const checked=await compiler.check({...options,machineBits,sources:made});
    assert.deepEqual(checked.diagnostics,[]);
    const laws=checked.evidence.filter(item=>item.stage==='law');
    assert.equal(laws.length,1);
    assert.ok(laws.every(item=>item.status==='not-verified'));
    const changed=await compiler.migrationComparison({...options,machineBits,from:'0.24',sources,
      migrated:{...options,machineBits,sources:made.map(source=>({...source,content:source.content.replace('using remembering','using other')}))}});
    assert.deepEqual(changed.diagnostics,[]);
    assert.equal(changed.migrationComparison.sourceUnits.status,'not-established');
    assert.equal(changed.migrationComparison.validated,false);
  }
});

test('single-law harness links retain settings, labels and selected handler associations',async()=>{
  for(const machineBits of [32,64]){
    const original=[{path:'signals.lawspec',content:content+'harness configured for signals is\nfor law `twice`\nrepeat 2\nlabel "twice"\nend\n'}];
    const report=await migrationReport(compiler,{version:1,targets:[]},{sources:original,machineBits});
    assert.deepEqual(report.diagnostics,[]);
    assert.equal(report.validated,true,JSON.stringify(report.blockers));
    const made=report.sourcePreview.sources.map(({path,content})=>({path,content}));
    assert.match(made[0].content,/for law "\|twice\|/);
    assert.match(made[0].content,/label "twice"/);
    const changed=await compiler.migrationComparison({...options,machineBits,from:'0.24',sources:original,
      migrated:{...options,machineBits,sources:made.map(source=>({...source,content:source.content.replace('repeat 2','repeat 3')}))}});
    assert.deepEqual(changed.diagnostics,[]);
    assert.equal(changed.migrationComparison.sourceUnits.status,'not-established');
  }
});

test('validated handler and harness links can be written and read through the canonical interface',async t=>{
  const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-handler-links-'));
  t.after(()=>rm(root,{recursive:true,force:true}));
  const original=content+'harness configured for signals is\nfor law `twice`\nrepeat 2\nlabel "twice"\nend\n';
  const config={version:1,sources:['signals.lawspec'],targets:[]};
  const configuration=JSON.stringify(config,null,2)+'\n';
  await writeFile(path.join(root,'signals.lawspec'),original);
  await writeFile(path.join(root,'lawspec.json'),configuration);
  const result=await writeMigration(compiler,root,'lawspec.json',configuration,
    {sources:[{path:'signals.lawspec',content:original}],machineBits:64});
  assert.equal(result.validated,true);
  assert.deepEqual(result.filesWritten,['signals.lawspec','lawspec.json']);
  const saved=await readFile(path.join(root,'signals.lawspec'),'utf8');
  assert.match(saved,/using remembering/);
  assert.match(saved,/for law "\|twice\|/);
  assert.match(saved,/label "twice"/);
  const checked=await compiler.check({...options,sources:[{path:'signals.lawspec',content:saved}]});
  assert.deepEqual(checked.diagnostics,[]);
  const laws=checked.evidence.filter(value=>value.stage==='law');
  assert.equal(laws.length,1);
  assert.equal(laws[0].status,'not-verified');
  const made=JSON.parse(await readFile(path.join(root,'lawspec.json'),'utf8'));
  assert.equal(made.version,2);
  assert.equal(made.languageProfile,options.languageProfile);
});
