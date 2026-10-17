// Generated from templates/npm/test/migration-write.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mkdtemp,mkdir,writeFile,readFile,rm,readdir,chmod,stat,symlink} from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {spawnSync} from 'node:child_process';
import {createCompiler} from '../api.mjs';
import {targets} from '../templates.mjs';
import {migrationReport,legacyLawLayers} from '../migrate.mjs';
import {writeMigration,commitMigration} from '../migration-write.mjs';

const compiler=await createCompiler();
const options={schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]}};
const old='unit demo\n-- literal spelling stays: "|a string"\ndefinition double (value :: Integer) :: Integer is value + value end\n'+
  'law `zero` is definition is double 0 = 0 end end\n';
const other='unit other\nimport demo as demo (double)\ndefinition apply (value :: Integer) :: Integer is demo.double value end\n';
const source=content=>[{path:'demo.lawspec',content}];
async function project(t,{content=old,languages=['python'],extra=false}={}){
  const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-write-migration-'));
  t.after(()=>rm(root,{recursive:true,force:true}));
  const sources=source(content);if(extra)sources.push({path:'other.lawspec',content:other});
  const config={version:1,sources:sources.map(file=>file.path),targets:languages.map(language=>({language,root:language})),
    generation:{cases:7,maxAttempts:70,maxShrinks:3,exhaustiveLimit:4096},machineBits:32,cache:false};
  const text=JSON.stringify(config,null,2)+'\n';
  for(const file of sources)await writeFile(path.join(root,file.path),file.content);
  await writeFile(path.join(root,'lawspec.json'),text);
  return {root,config,text,input:{sources,machineBits:32,generation:config.generation}};
}
const load=async p=>JSON.parse(await readFile(path.join(p.root,'lawspec.json'),'utf8'));
const canonical=async p=>compiler.check({...options,sources:await Promise.all(p.input.sources.map(async file=>
  ({path:file.path,content:await readFile(path.join(p.root,file.path),'utf8')})))});

test('read-only validation distinguishes source migration, no target checks and unverified laws',async t=>{
  const p=await project(t,{languages:[]});
  const report=await migrationReport(compiler,p.config,p.input);
  assert.equal(report.validated,true,JSON.stringify(report.blockers));
  assert.equal(report.validation.status,'validated-under-existing-assumptions');
  assert.equal(report.correspondence.generatedBehavior.status,'not-requested');
  assert.equal(report.correspondence.targetGeneration.status,'not-requested');
  assert.equal(report.validation.nativeConformance,'not-established');
  assert.equal(report.validation.lawVerification,'not-established-by-migration');
  assert.deepEqual(report.filesWritten,[]);assert.deepEqual(report.blockers,[]);
  assert.equal(await readFile(path.join(p.root,'demo.lawspec'),'utf8'),old);
  assert.equal(await readFile(path.join(p.root,'lawspec.json'),'utf8'),p.text);
});

test('project writing migrates every source and all 17 target configurations while retaining generation and native code',async t=>{
  const p=await project(t,{languages:targets,extra:true});
  await mkdir(path.join(p.root,'python'));await writeFile(path.join(p.root,'python/application.py'),'existing_native = 7\n');
  const report=await writeMigration(compiler,p.root,'lawspec.json',p.text,p.input);
  assert.equal(report.validated,true);assert.equal(report.generationPreview.configurationCount,17);
  assert.equal(report.correspondence.generatedBehavior.status,'matched-under-existing-assumptions');
  assert.deepEqual(report.filesWritten,['demo.lawspec','other.lawspec','lawspec.json']);
  const config=await load(p);assert.equal(config.version,2);assert.equal(config.languageProfile,'1.0-rc.1');
  assert.deepEqual(config.verification,{layers:legacyLawLayers});
  assert.deepEqual(config.generation,p.config.generation);assert.equal(config.machineBits,32);assert.equal(config.cache,false);
  assert.deepEqual(config.targets,p.config.targets);
  assert.match(await readFile(path.join(p.root,'demo.lawspec'),'utf8'),/-- literal spelling stays: "\|a string"/);
  assert.equal(await readFile(path.join(p.root,'python/application.py'),'utf8'),'existing_native = 7\n');
  const checked=await canonical(p);assert.deepEqual(checked.diagnostics,[]);
  assert.equal(checked.verification.intrinsicDefinitionChecks,true);
  assert.equal(checked.verification.selection,'no-selected-checks');
  assert.ok(checked.evidence.filter(row=>row.stage==='law').every(row=>row.status==='not-verified'));
  assert.deepEqual((await readdir(p.root)).sort(),['demo.lawspec','lawspec.json','other.lawspec','python']);
  await assert.rejects(writeMigration(compiler,p.root,'lawspec.json',await readFile(path.join(p.root,'lawspec.json'),'utf8'),p.input),
    error=>error.diagnostics[0].code==='migration-configuration');
});

test('changed unbound native payload APIs cannot authorize any project write',async t=>{
  const p=await project(t,{content:'unit demo\ntype Parcel is | Packed first :: Bool last :: UInt8 end\ncopy :: Parcel -> Parcel'});
  await assert.rejects(writeMigration(compiler,p.root,'lawspec.json',p.text,p.input),error=>{
    assert.equal(error.diagnostics[0].code,'migration-incomplete');assert.match(error.message,/native.*layouts differ/i);return true;});
  assert.equal(await readFile(path.join(p.root,'demo.lawspec'),'utf8'),p.input.sources[0].content);
  assert.equal(await readFile(path.join(p.root,'lawspec.json'),'utf8'),p.text);
  assert.deepEqual((await readdir(p.root)).sort(),['demo.lawspec','lawspec.json']);
});

test('ordered collection migration writes only after full correspondence across all 17 targets',async t=>{
  const content=await readFile(new URL('../../test/fixtures/migration-collections-0.24.lawspec',import.meta.url),'utf8');
  const p=await project(t,{content,languages:targets});
  const report=await writeMigration(compiler,p.root,'lawspec.json',p.text,p.input);
  assert.equal(report.validated,true,JSON.stringify(report.blockers));
  assert.equal(report.generationPreview.configurationCount,17);
  assert.equal(report.correspondence.generatedBehavior.status,'matched-under-existing-assumptions');
  assert.deepEqual(report.blockers,[]);
  assert.deepEqual(report.filesWritten,['demo.lawspec','lawspec.json']);
  const checked=await canonical(p);assert.deepEqual(checked.diagnostics,[]);
  assert.equal(checked.verification.intrinsicDefinitionChecks,true);
  assert.match(await readFile(path.join(p.root,'demo.lawspec'),'utf8'),/SortedSet Integer/);
  assert.equal((await load(p)).version,2);
});

test('mandatory definition errors cannot be hidden by forged earlier reports or disabled law layers',async t=>{
  const p=await project(t,{content:'unit demo\ndefinition unsafe (n :: Integer) :: Integer is 1 / n end'});
  await assert.rejects(writeMigration(compiler,p.root,'lawspec.json',p.text,p.input),error=>{
    assert.ok(error.diagnostics.length);assert.notEqual(error.diagnostics[0].code,'migration-incomplete');return true;});
  assert.equal(await readFile(path.join(p.root,'lawspec.json'),'utf8'),p.text);
  assert.equal(await readFile(path.join(p.root,'demo.lawspec'),'utf8'),p.input.sources[0].content);
});

test('fresh validation catches stale sources and configuration before any replacement',async t=>{
  for(const changed of ['demo.lawspec','lawspec.json']){
    const p=await project(t);
    const changedText=changed==='demo.lawspec'?old+'\n-- concurrent user edit\n':p.text+'\n';
    const wrapped={...compiler,migrationGeneration:async input=>{
      const result=await compiler.migrationGeneration(input);await writeFile(path.join(p.root,changed),changedText);return result;
    }};
    await assert.rejects(writeMigration(wrapped,p.root,'lawspec.json',p.text,p.input),error=>error.diagnostics[0].code==='migration-stale');
    assert.equal(await readFile(path.join(p.root,changed),'utf8'),changedText);
    const untouched=changed==='demo.lawspec'?'lawspec.json':'demo.lawspec';
    assert.equal(await readFile(path.join(p.root,untouched),'utf8'),untouched==='lawspec.json'?p.text:old);
    assert.ok((await readdir(p.root)).every(file=>!file.includes('lawspec-migrat')));
  }
});

test('dependent files and unchanged sources are rechecked after staging and abort the whole write',async t=>{
  const p=await project(t,{extra:true});
  await assert.rejects(writeMigration(compiler,p.root,'lawspec.json',p.text,p.input,
    {recheck:async()=>{throw new Error('dependency changed');}}),/dependency changed/);
  assert.equal(await readFile(path.join(p.root,'demo.lawspec'),'utf8'),old);
  assert.equal(await readFile(path.join(p.root,'other.lawspec'),'utf8'),other);
  assert.equal(await readFile(path.join(p.root,'lawspec.json'),'utf8'),p.text);
  const unchanged=path.join(p.root,'watch.txt');await writeFile(unchanged,'old');
  await assert.rejects(commitMigration(p.root,[{path:'demo.lawspec',expected:old,content:'new'},
    {path:'watch.txt',expected:'old',content:'old'}],{recheck:()=>writeFile(unchanged,'editor')}),
    error=>error.diagnostics[0].code==='migration-stale');
  assert.equal(await readFile(path.join(p.root,'demo.lawspec'),'utf8'),old);
  assert.equal(await readFile(unchanged,'utf8'),'editor');
});

test('a late filesystem commit error restores earlier replacements and retains recovery paths when cleanup is denied',
  {skip:process.platform==='win32'||process.getuid?.()===0?'requires ordinary POSIX filesystem permissions':false},async t=>{
    const p=await project(t);const child=path.join(p.root,'later');await mkdir(child);
    await writeFile(path.join(child,'second'),'old second');
    try{
      await assert.rejects(commitMigration(p.root,[{path:'demo.lawspec',expected:old,content:'new first'},
        {path:'later/second',expected:'old second',content:'new second'}],{recheck:()=>chmod(child,0o555)}),error=>{
          assert.equal(error.diagnostics[0].code,'migration-write');assert.ok(error.recovery.length);return true;});
      assert.equal(await readFile(path.join(p.root,'demo.lawspec'),'utf8'),old);
      assert.equal(await readFile(path.join(child,'second'),'utf8'),'old second');
    }finally{await chmod(child,0o755);}
});

test('successful replacements retain permissions and migration locks exclude concurrent writers',async t=>{
  const p=await project(t,{languages:[]});await chmod(path.join(p.root,'demo.lawspec'),0o640);
  const lock=path.join(p.root,'.lawspec-migration.lock');await writeFile(lock,'other migration');
  await assert.rejects(writeMigration(compiler,p.root,'lawspec.json',p.text,p.input),/lock already exists/);
  assert.equal(await readFile(lock,'utf8'),'other migration');await rm(lock);
  await writeMigration(compiler,p.root,'lawspec.json',p.text,p.input);
  assert.equal((await stat(path.join(p.root,'demo.lawspec'))).mode&0o777,0o640);
});

test('traversal and symbolic links cannot replace files outside the project',async t=>{
  const p=await project(t),outside=await project(t);
  await assert.rejects(commitMigration(p.root,[{path:'../elsewhere',expected:'old',content:'new'}]),/Unsafe/);
  await symlink(path.join(outside.root,'demo.lawspec'),path.join(p.root,'linked.lawspec'));
  await assert.rejects(commitMigration(p.root,[{path:'linked.lawspec',expected:old,content:'new'}]),/symbolic-link/);
  assert.equal(await readFile(path.join(outside.root,'demo.lawspec'),'utf8'),old);
});

test('migrate CLI defaults to a read-only report and requires --write to change a validated project',async t=>{
  const p=await project(t,{languages:[]});const cli=new URL('../bin/lawspec.mjs',import.meta.url).pathname;
  const run=args=>spawnSync(process.execPath,[cli,'migrate','--from','0.24',...args],{cwd:p.root,encoding:'utf8',maxBuffer:32e6});
  const preview=run(['--json']);assert.equal(preview.status,0,preview.stdout+preview.stderr);
  assert.equal(JSON.parse(preview.stdout).validated,true);
  assert.equal(await readFile(path.join(p.root,'demo.lawspec'),'utf8'),old);
  const conflict=run(['--write','--dry-run']);assert.notEqual(conflict.status,0);
  assert.equal(await readFile(path.join(p.root,'lawspec.json'),'utf8'),p.text);
  const written=run(['--write','--json']);assert.equal(written.status,0,written.stdout+written.stderr);
  assert.deepEqual(JSON.parse(written.stdout).filesWritten,['demo.lawspec','lawspec.json']);
  assert.equal((await load(p)).version,2);assert.deepEqual((await canonical(p)).diagnostics,[]);
});


test('every configured source and directory member must belong to the checked project snapshot',async t=>{
  const p=await project(t,{extra:true});
  await assert.rejects(writeMigration(compiler,p.root,'lawspec.json',p.text,{...p.input,sources:p.input.sources.slice(0,1)}),
    error=>error.diagnostics[0].code==='migration-stale');
  assert.equal(await readFile(path.join(p.root,'lawspec.json'),'utf8'),p.text);
  const q=await project(t);q.config.sources=['.'];q.text=JSON.stringify(q.config)+'\n';
  await writeFile(path.join(q.root,'lawspec.json'),q.text);
  const wrapped={...compiler,migrationGeneration:async input=>{
    const result=await compiler.migrationGeneration(input);await writeFile(path.join(q.root,'added.lawspec'),'unit added\n');return result;
  }};
  await assert.rejects(writeMigration(wrapped,q.root,'lawspec.json',q.text,q.input),error=>error.diagnostics[0].code==='migration-stale');
  assert.equal(await readFile(path.join(q.root,'demo.lawspec'),'utf8'),old);
  assert.equal(await readFile(path.join(q.root,'lawspec.json'),'utf8'),q.text);
});

test('grouped payload writes retain the admitted native field paths, types and existing argument positions',async t=>{
  const content='unit demo\ntype Parcel is | Packed last :: UInt8 first :: Bool end\ncopy :: Parcel -> Parcel';
  const p=await project(t,{content});
  p.config.targets[0].nativeBindings={types:[{type:'demo::type::Parcel',native:['application','Parcel'],constructors:[{
    constructor:'Packed',native:['application','Packed'],style:'variant',fields:[
      {field:'last',path:[],argument:1,native:'tail'},{field:'first',path:[],argument:0,native:'head'}]}]}],
    functions:[{declaration:'demo::copy',native:['application','copy']}]};
  p.text=JSON.stringify(p.config)+'\n';await writeFile(path.join(p.root,'lawspec.json'),p.text);
  const report=await writeMigration(compiler,p.root,'lawspec.json',p.text,p.input);
  assert.equal(report.validated,true);assert.equal(report.correspondence.nativeBoundary.status,'matched');
  const made=await load(p);
  assert.deepEqual(made.targets[0].nativeBindings.types[0].constructors[0].fields,[
    {field:'value',path:['first'],argument:0,native:'head'},{field:'value',path:['last'],argument:1,native:'tail'}]);
  const checked=await compiler.check({...options,machineBits:32,sources:[{path:'demo.lawspec',
    content:await readFile(path.join(p.root,'demo.lawspec'),'utf8')}],nativeBindings:made.targets[0].nativeBindings});
  assert.deepEqual(checked.diagnostics,[]);
  assert.equal(report.validation.nativeConformance,'not-established');
});


test('one-off native bindings and configuration overrides cannot authorize a different persisted project',async t=>{
  const p=await project(t);
  for(const input of [{...p.input,target:'python',nativeBindings:{}},{...p.input,machineBits:64},
    {...p.input,generation:{...p.input.generation,cases:8}}]){
    await assert.rejects(writeMigration(compiler,p.root,'lawspec.json',p.text,input),
      error=>error.diagnostics[0].code==='migration-configuration');
    assert.equal(await readFile(path.join(p.root,'lawspec.json'),'utf8'),p.text);
    assert.equal(await readFile(path.join(p.root,'demo.lawspec'),'utf8'),old);
  }
});

test('an unestablished generic input-domain policy blocks writing even when law verification is unselected',async t=>{
  const content='unit demo\nlaw `kept` (operation :: a -> a) requires Eq a is '+
    'definition is `for all` (value :: a) . operation value = value end end';
  const p=await project(t,{content,languages:[]});
  await assert.rejects(writeMigration(compiler,p.root,'lawspec.json',p.text,p.input),error=>{
    assert.equal(error.diagnostics[0].code,'migration-incomplete');assert.match(error.message,/empty-domain/);return true;
  });
  assert.equal(await readFile(path.join(p.root,'demo.lawspec'),'utf8'),content);
  assert.equal(await readFile(path.join(p.root,'lawspec.json'),'utf8'),p.text);
  assert.deepEqual((await readdir(p.root)).sort(),['demo.lawspec','lawspec.json']);
});


test('invalid target roots and omitted package inputs cannot become a validated persisted configuration',async t=>{
  for(const change of [config=>{delete config.targets[0].root;},config=>{config.targets.push({...config.targets[0]});},
    config=>{config.packages=['dependency'];},config=>{config.dependencies={dependency:'1.0.0'};}]){
    const p=await project(t);change(p.config);p.text=JSON.stringify(p.config)+'\n';
    await writeFile(path.join(p.root,'lawspec.json'),p.text);
    await assert.rejects(writeMigration(compiler,p.root,'lawspec.json',p.text,p.input),
      error=>error.diagnostics[0].code==='migration-configuration');
    assert.equal(await readFile(path.join(p.root,'lawspec.json'),'utf8'),p.text);
    assert.equal(await readFile(path.join(p.root,'demo.lawspec'),'utf8'),old);
  }
});

test('the published canonical Chapter 6 specification retains its authored inventory and canonical formatting',async()=>{
  const file=new URL('../../examples/chap06/assembler.lawspec',import.meta.url);
  const content=await readFile(file,'utf8'),sources=[{path:'chap06.lawspec',content}];
  const checked=await compiler.check({...options,sources});assert.deepEqual(checked.diagnostics,[]);
  const owned=id=>id.startsWith('nand2tetris.chap06::');
  assert.equal(checked.laws.filter(law=>owned(law.id)).length,23);
  assert.equal(checked.laws.filter(law=>owned(law.id)).flatMap(law=>law.examples).length,66);
  assert.equal(checked.dataTypes.filter(type=>owned(type.id)).length,7);
  // These are authored declaration lines in the compiler-accepted canonical
  // fixture; lowered field helpers are additional implementation definitions.
  assert.equal(content.match(/^function /gm).length,25);
  assert.equal(content.match(/^refinement /gm).length,2);
  assert.equal(content.match(/^\s+example /gm).length,1);
  assert.equal(content.match(/^\s+row /gm).length,65);
  const formatted=await compiler.format({...options,sources});assert.deepEqual(formatted.diagnostics,[]);
  assert.equal(formatted.formattedSources[0].content,content);
  assert.equal(checked.verification.selection,'no-selected-checks');
});
