import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile,writeFile,mkdir,mkdtemp,rm,readdir} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {writeMigration} from '../migration-write.mjs';
import {targets} from '../templates.mjs';
import path from 'node:path';
import {createCompiler} from '../api.mjs';
import {collectSources} from '../files.mjs';
import {migrationReport} from '../migrate.mjs';
import {migrationOffset} from '../migration-source.mjs';

test('the versioned orders package preview retains original import and quoted-law source ranges',async()=>{
  const fixture=JSON.parse(await readFile(new URL('../../test/fixtures/packages-0.24.json',import.meta.url),'utf8'));
  const {config,input}=fixture;
  const {sources,packages}=input;
  const report=await migrationReport(await createCompiler(),config,{sources,packages,dependencies:config.dependencies});
  assert.deepEqual(report.diagnostics,[]);
  assert.deepEqual(report.sourcePreview.diagnostics,[]);
  const content=sources[0].content;
  const inventory=report.baseline.sourceSyntax.find(source=>source.path===sources[0].path);
  const text=node=>content.slice(migrationOffset(content,node.span.start),migrationOffset(content,node.span.end));
  for(const node of inventory.nodes){migrationOffset(content,node.span.start);migrationOffset(content,node.span.end);}
  const band=inventory.nodes.find(node=>node.kind==='import-item'&&node.name==='Band');
  assert.ok(band);assert.equal(text(band),'Band');
  for(const name of ['commutative','idempotent']){
    const node=inventory.nodes.find(node=>node.kind==='quoted-name'&&node.name===name);
    assert.ok(node,name);assert.equal(text(node),'`'+name+'`');
  }
  const preview=report.sourcePreview.sources.find(source=>source.path===sources[0].path);
  assert.match(preview.content,/law "\|commutative\|/);
  assert.match(preview.content,/law "\|idempotent\|/);
  for(const segment of preview.segments.filter(segment=>segment.retained))
    assert.equal(preview.content.slice(segment.start,segment.end),content.slice(segment.originalStart,segment.originalEnd));
  assert.equal(report.sourcePreview.canonicalCheck.status,'accepted');
  assert.equal(report.sourcePreview.packages.length,packages.length);
  assert.equal(report.validated,false,'Unestablished generic source domains remain a write blocker.');
  assert.equal(report.correspondence.sourceTemplates.domainPolicies.status,'not-established');
  if(report.sourcePreview.canonicalCheck.status==='rejected'){
    assert.equal(report.validated,false,'An unadmitted dependency cannot authorize a project write.');
    assert.deepEqual(report.filesWritten,[]);
  }
});


async function finiteProject(t){
  const directory=await mkdtemp(path.join(tmpdir(),'lawspec-package-migration-'));
  t.after(()=>rm(directory,{recursive:true,force:true}));
  const root=path.join(directory,'orders'),dependency=path.join(directory,'domain');
  await mkdir(root);await mkdir(path.join(dependency,'src'),{recursive:true});
  const source='unit shop.orders\nimport shop.domain as domain (Flag)\n'+
    'definition twice (value :: Flag) :: Flag is domain.flip (domain.flip value) end\n'+
    'law `same` is definition is `for all` (value :: Flag) . twice value = value end end\n';
  const packaged='unit shop.domain\ntype Flag is | Off | On end\n'+
    'definition flip (value :: Flag) :: Flag is match value with | Off -> On | On -> Off end end\n';
  const manifest={name:'shop.domain',version:'1.0.0',sources:['src'],dependencies:{}};
  const config={version:1,sources:['orders.lawspec'],targets:[],packages:['../domain'],dependencies:{'shop.domain':'^1.0.0'}};
  const configuration=JSON.stringify(config,null,2)+'\n';
  await writeFile(path.join(root,'orders.lawspec'),source);
  await writeFile(path.join(root,'lawspec.json'),configuration);
  await writeFile(path.join(dependency,'lawspec-package.json'),JSON.stringify(manifest)+'\n');
  await writeFile(path.join(dependency,'src/domain.lawspec'),packaged);
  const input={sources:await collectSources(root,config.sources),dependencies:config.dependencies,
    packages:[{name:manifest.name,version:manifest.version,dependencies:{},sources:await collectSources(dependency,manifest.sources,root)}]};
  return {directory,root,dependency,source,packaged,manifest,config,configuration,input};
}

test('package source previews preserve exact paths and validate the complete finite project',async t=>{
  const p=await finiteProject(t),compiler=await createCompiler();
  const report=await migrationReport(compiler,p.config,p.input);
  assert.deepEqual(report.diagnostics,[]);
  assert.equal(report.validated,true,JSON.stringify(report.blockers));
  assert.equal(report.sourcePreview.packages.length,1);
  assert.equal(report.sourcePreview.packages[0].sources[0].path,'../domain/src/domain.lawspec');
  assert.match(report.sourcePreview.packages[0].sources[0].content,/end function/);
  assert.equal(report.correspondence.sourceTemplates.status,'matched');
  assert.equal(await readFile(path.join(p.dependency,'src/domain.lawspec'),'utf8'),p.packaged);
  const written=await writeMigration(compiler,p.root,'lawspec.json',p.configuration,p.input,{recheck:async()=>{}});
  assert.deepEqual(written.filesWritten,['orders.lawspec','../domain/src/domain.lawspec','lawspec.json']);
  const canonical=await compiler.check({schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:['exhaustive']},
    sources:await collectSources(p.root,p.config.sources),dependencies:p.config.dependencies,
    packages:[{...p.input.packages[0],sources:await collectSources(p.dependency,p.manifest.sources,p.root)}]});
  assert.deepEqual(canonical.diagnostics,[]);
  assert.equal(canonical.evidence.find(item=>item.stage==='law').status,'exhaustively-checked');
  assert.deepEqual((await readdir(p.root)).sort(),['lawspec.json','orders.lawspec']);
  assert.deepEqual((await readdir(path.join(p.dependency,'src'))).sort(),['domain.lawspec']);
});

test('package additions, edits and manifest changes abort before replacing any admitted source',async t=>{
  const compiler=await createCompiler();
  for(const change of ['source','member','manifest']){
    const p=await finiteProject(t);
    await assert.rejects(writeMigration(compiler,p.root,'lawspec.json',p.configuration,p.input,{recheck:async()=>{
      if(change==='source')await writeFile(path.join(p.dependency,'src/domain.lawspec'),p.packaged+'-- edit\n');
      if(change==='member')await writeFile(path.join(p.dependency,'src/added.lawspec'),'unit shop.domain.added\n');
      if(change==='manifest')await writeFile(path.join(p.dependency,'lawspec-package.json'),JSON.stringify({...p.manifest,version:'2.0.0'}));
    }}),error=>error.diagnostics[0].code==='migration-stale');
    assert.equal(await readFile(path.join(p.root,'orders.lawspec'),'utf8'),p.source);
    assert.equal(await readFile(path.join(p.root,'lawspec.json'),'utf8'),p.configuration);
    assert.equal(await readFile(path.join(p.dependency,'src/domain.lawspec'),'utf8'),p.packaged+(change==='source'?'-- edit\n':''));
    assert.deepEqual((await readdir(p.root)).sort(),['lawspec.json','orders.lawspec']);
  }
});


test('all configured targets compare emission with migrated package sources on both request sides',async t=>{
  const p=await finiteProject(t),compiler=await createCompiler();
  const config={...p.config,targets:targets.map(language=>({language,root:language}))};
  const report=await migrationReport(compiler,config,p.input);
  assert.deepEqual(report.diagnostics,[]);
  assert.equal(report.validated,true,JSON.stringify(report.blockers));
  assert.equal(report.generationPreview.configurationCount,17);
  assert.deepEqual(report.generationPreview.targets.map(row=>row.target),targets);
  assert.ok(report.generationPreview.targets.every(row=>row.status==='accepted'&&row.nativeBoundary.status==='matched'));
  assert.equal(report.correspondence.generatedBehavior.nativeExecution,'not-performed');
  assert.equal(await readFile(path.join(p.dependency,'src/domain.lawspec'),'utf8'),p.packaged);
});
