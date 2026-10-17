// Generated from templates/npm/test/migration-packages.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createCompiler} from '../api.mjs';
import {collectSources} from '../files.mjs';
import {migrationReport} from '../migrate.mjs';
import {migrationOffset} from '../migration-source.mjs';

test('the versioned orders package preview retains original import and quoted-law source ranges',async()=>{
  const root=fileURLToPath(new URL('../../examples/packages/orders/',import.meta.url));
  const config=JSON.parse(await readFile(path.join(root,'lawspec.json'),'utf8'));
  const sources=await collectSources(root,config.sources);
  const packages=await Promise.all(config.packages.map(async relative=>{
    const directory=path.resolve(root,relative);
    const manifest=JSON.parse(await readFile(path.join(directory,'lawspec-package.json'),'utf8'));
    return {name:manifest.name,version:manifest.version,dependencies:manifest.dependencies??{},
      sources:await collectSources(directory,manifest.sources,root)};
  }));
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
  if(report.sourcePreview.canonicalCheck.status==='rejected'){
    assert.equal(report.validated,false,'An unadmitted dependency cannot authorize a project write.');
    assert.deepEqual(report.filesWritten,[]);
  }
});
