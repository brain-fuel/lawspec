// Generated from templates/npm/test/migration-generation.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createHash} from 'node:crypto';
import {createCompiler} from '../api.mjs';
import {targets} from '../templates.mjs';
import {migrationReport,legacyLawLayers} from '../migrate.mjs';
import {bindingDigest} from '../migration-bindings.mjs';
import {checkGenerationReceipt} from '../migration-generation.mjs';

const compiler=await createCompiler();
const options={schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]}};
const generation={cases:100,maxAttempts:10000,maxShrinks:1000,exhaustiveLimit:4096};
const old='unit generation\ndefinition same (value :: Bool) :: Bool is value end\n'+
  'law `identity` is definition is `for all` (value :: Bool) . same value = value end end';
const made='unit generation\nfunction same (value :: Bool) -> Bool is value end function\n'+
  'law identity is definition: for all (value :: Bool) => same value must be value end end end';
const sources=content=>[{path:'génération 🧪.lawspec',content}];
const request=(target='python',machineBits=64,minify=false)=>({...options,verification:{layers:[]},target,machineBits,minify,generation:{...generation},from:'0.24',
  sources:sources(old),nativeBindings:{},migrated:{...options,verification:{layers:[]},target,machineBits,minify,generation:{...generation},sources:sources(made)}});
const sha=value=>createHash('sha256').update(value).digest('hex');
const manifest=result=>result.files.map(file=>({path:file.path,ownership:file.ownership,placement:file.placement,
  contentDigest:sha(file.content),...(file.adapterReference===undefined?{}:{adapterReferenceDigest:sha(file.adapterReference)})}))
  .sort((a,b)=>a.path<b.path?-1:a.path>b.path?1:0);

test('migration generation records complete emitter artifacts on all 17 targets without claiming native execution',async()=>{
  for(const target of targets){
    const result=await compiler.migrationGeneration(request(target));
    assert.deepEqual(result.diagnostics,[],target);
    const evidence=result.migrationGeneration;
    assert.equal(evidence.status,'accepted',JSON.stringify([target,evidence]));
    assert.equal(evidence.before.status,'accepted');assert.equal(evidence.after.status,'accepted');
    assert.ok(evidence.before.files.some(file=>file.placement==='test'),'legacy harnesses were silently omitted');
    assert.ok(evidence.after.files.some(file=>file.placement==='test'),'canonical harnesses were silently omitted');
    for(const side of ['before','after'])assert.equal(evidence[side].artifactDigest,bindingDigest(evidence[side].files));
    assert.equal(evidence.nativeBoundary.status,'matched',target);
    assert.equal(evidence.nativeConformance,'not-established');
    assert.equal(evidence.lawVerification,'not-established-by-generation');
    assert.equal(result.verification.selection,'no-selected-checks');
    assert.equal(result.verification.intrinsicDefinitionChecks,true);
  }
});

test('receipt manifests match independently requested legacy and canonical generation in both widths and layouts',async()=>{
  for(const machineBits of [32,64])for(const minify of [false,true]){
    const input=request('python',machineBits,minify);
    const checked=await compiler.migrationGeneration(input);assert.deepEqual(checked.diagnostics,[]);
    const before=await compiler.planGeneration({schemaVersion:4,target:input.target,machineBits,minify,generation,sources:input.sources});
    const after=await compiler.planGeneration({...input.migrated,verification:{layers:legacyLawLayers}});
    assert.deepEqual(before.diagnostics,[]);assert.deepEqual(after.diagnostics,[]);
    assert.deepEqual(checked.migrationGeneration.before.files,manifest(before));
    assert.deepEqual(checked.migrationGeneration.after.files,manifest(after));
  }
});

test('the report validates configured output directories under retained native assumptions',async()=>{
  const config={version:1,targets:[{language:'python',root:'python',sourceDir:'app',testDir:'checks'}]};
  const report=await migrationReport(compiler,config,{sources:sources(old),machineBits:32,minify:true});
  assert.deepEqual(report.diagnostics,[]);assert.equal(report.generationPreview.status,'accepted',JSON.stringify(report.generationPreview));
  const row=report.generationPreview.targets[0];
  assert.equal(row.evidence.sourceDir,'app');assert.equal(row.evidence.testDir,'checks');assert.equal(row.evidence.minify,true);
  assert.ok(row.evidence.after.files.some(file=>file.path.startsWith('app/')));
  assert.ok(row.evidence.after.files.some(file=>file.path.startsWith('checks/')));
  assert.equal(report.correspondence.targetGeneration.status,'accepted');
  assert.equal(report.correspondence.generatedBehavior.status,'matched-under-existing-assumptions');
  assert.equal(report.validated,true);assert.deepEqual(report.filesWritten,[]);
});

test('the report makes zero configured generation checks explicit',async()=>{
  const report=await migrationReport(compiler,{version:1,targets:[]},{sources:sources(old)});
  assert.equal(report.generationPreview.status,'not-requested');
  assert.equal(report.correspondence.nativeBoundary.status,'not-requested');
  assert.equal(report.generationPreview.configurationCount,0);assert.deepEqual(report.generationPreview.targets,[]);
  assert.equal(report.validated,true);
  assert.equal(report.correspondence.generatedBehavior.status,'not-requested');
});

test('generation receipt guards reject stale inputs, forged outcomes and malformed artifact inventories',async()=>{
  const input=request();
  const baseline=await compiler.migrationBaseline(input);
  const canonical=await compiler.check({...input.migrated,migrationSnapshot:true});
  const result=await compiler.migrationGeneration(input);assert.deepEqual(result.diagnostics,[]);
  const evidence=result.migrationGeneration,proposal=evidence.bindingProposal;
  const check=(changed,req=input)=>checkGenerationReceipt(baseline.migrationSemantics,canonical.migrationSemantics,req,proposal,changed);
  assert.equal(check(evidence).status,'accepted');
  for(const mutate of [
    e=>{e.version=2;},e=>{e.target='java';},e=>{e.machineBits=32;},e=>{e.minify=true;},
    e=>{e.sourceDir='elsewhere';},e=>{e.testDir='elsewhere';},e=>{delete e.generation;},e=>{e.generation.cases++;},
    e=>{e.sourceInputs.before='0'.repeat(64);},e=>{e.sourceInputs.after='0'.repeat(64);},
    e=>{e.planning='none';},e=>{e.nativeConformance='proved';},e=>{e.lawVerification='verified';},
    e=>{e.bindingProposal.bindings.after='0'.repeat(64);},e=>{e.after.status='rejected';},
    e=>{e.before.files=[];e.before.artifactDigest=bindingDigest([]);},
    e=>{e.after.files[0].contentDigest='bad';e.after.artifactDigest=bindingDigest(e.after.files);},
    e=>{e.after.files[0].unknown=true;e.after.artifactDigest=bindingDigest(e.after.files);},
    e=>{e.after.files[0].ownership='assumed';e.after.artifactDigest=bindingDigest(e.after.files);},
    e=>{e.after.files[0].path='../escape';e.after.artifactDigest=bindingDigest(e.after.files);},
    e=>{e.after.files.push(e.after.files[0]);e.after.artifactDigest=bindingDigest(e.after.files);},
    e=>{e.after.artifactDigest='0'.repeat(64);},
  ]){const changed=structuredClone(evidence);mutate(changed);assert.equal(check(changed).status,'not-established',mutate.toString());}
  assert.equal(check(evidence,{...input,sources:sources(old+'\n ')}).status,'not-established');
  assert.equal(check(evidence,{...input,dependencies:{unrelated:'1.0.0'}}).status,'not-established');
  assert.equal(check(evidence,{...input,migrated:{...input.migrated,sources:sources(made+'\n ')}}).status,'not-established');
});

test('migration generation rejects mismatched profiles, widths, layouts and limits and retains mandatory errors',async()=>{
  for(const mutate of [i=>{i.schemaVersion=4;},i=>{delete i.languageProfile;},i=>{i.from='0.23';},
    i=>{i.migrated.schemaVersion=4;},i=>{i.migrated.machineBits=32;},i=>{i.migrated.target='java';},
    i=>{i.migrated.sourceDir='other';},i=>{i.migrated.minify=true;},i=>{i.migrated.generation.cases++;},
    i=>{i.verification.layers=['proof'];},i=>{i.migrated.verification.layers=['property'];}]){
    const input=request();mutate(input);
    assert.ok((await compiler.migrationGeneration(input)).diagnostics.length,mutate.toString());
  }
  const invalid=request();invalid.sources=sources('unit generation\ndefinition unsafe (n :: Integer) :: Integer is 1 / n end');
  const result=await compiler.migrationGeneration(invalid);
  assert.ok(result.diagnostics.length);assert.equal(result.migrationComparisonInput,'before');
  assert.equal(result.migrationGeneration,undefined);
});

test('a compiler without generation support leaves the target check explicitly unavailable',async()=>{
  const {migrationGeneration:omitted,...older}=compiler;
  const report=await migrationReport(older,{version:1,targets:[{language:'python',root:'python'}]},{sources:sources(old)});
  assert.equal(report.generationPreview.status,'not-established');
  assert.match(report.generationPreview.targets[0].reason,/generation-capable/);
  assert.equal(report.validated,false);
});


test('generation rejection is reported independently for each side of an admitted comparison',async()=>{
  const input=request();
  input.sources=sources('unit empty\ntype Empty is Loop next :: Empty end\nlaw `kept` is definition is `for all` (value :: Empty) . value = value end end');
  input.migrated.sources=sources('unit empty\ntype Empty is one of Loop of type Empty end type\nlaw kept is definition: for all (value :: Empty) => value must be value end end end');
  const result=await compiler.migrationGeneration(input);assert.deepEqual(result.diagnostics,[]);
  assert.equal(result.migrationGeneration.status,'not-established');
  assert.equal(result.migrationGeneration.before.status,'rejected');
  assert.match(result.migrationGeneration.before.diagnostics[0].message,/uninhabited input domain/);
  assert.equal(result.migrationGeneration.after.status,'accepted');
  assert.equal(result.migrationGeneration.nativeConformance,'not-established');
});

test('grouped native payload generation uses the admitted typed proposal on every supported binding target',async()=>{
  for(const target of targets){
    const input=request(target);
    input.sources=sources('unit parcel\ntype Parcel is | Packed last :: Bool first :: Bool end\ncopy :: Parcel -> Parcel');
    input.migrated.sources=sources('unit parcel\ntype Parcel is one of Packed of type record{last :: Bool first :: Bool} end type\ncopy :: Parcel -> Parcel');
    const owner=['fsharp','swift','haskell','elixir'].includes(target)?'Application':'application';
    const mapped={types:[{type:'parcel::type::Parcel',native:[owner,'Parcel'],constructors:[{
      constructor:'Packed',native:target==='erlang'?['packed']:target==='swift'?[owner,'Parcel','packed']:[owner,'Packed'],
      style:'variant',fields:[{field:'first',native:'head'},{field:'last',native:'tail'}],
    }]}],functions:[{declaration:'parcel::copy',native:[owner,'copy']}]};
    if(target==='go'){
      mapped.goImports=[{alias:owner,path:'native_layout_fixture/application'}];mapped.functions[0].native=[owner,'Copy'];
      for(const field of mapped.types[0].constructors[0].fields)field.native=field.native[0].toUpperCase()+field.native.slice(1);
    }
    if(target==='rust'){
      mapped.rustCrate='native_layout_fixture';mapped.types[0].native.unshift('crate');
      mapped.types[0].constructors[0].native.unshift('crate');mapped.functions[0].native=['crate',owner,'copy'];
    }
    input.nativeBindings=mapped;
    const result=await compiler.migrationGeneration(input);assert.deepEqual(result.diagnostics,[],target);
    const evidence=result.migrationGeneration;
    if(['csharp','clojure'].includes(target)){
      assert.equal(evidence.status,'not-established',target);assert.equal(evidence.before.status,'rejected',target);continue;
    }
    assert.equal(evidence.status,'accepted',JSON.stringify([target,evidence]));
    assert.equal(evidence.nativeBoundary.status,'matched',JSON.stringify([target,evidence.nativeBoundary]));
    assert.equal(evidence.bindingProposal.changes[0].kind,'grouped-record-payload');
    const independent=await compiler.planGeneration({...input.migrated,
      nativeBindings:evidence.bindingProposal.proposedNativeBindings,verification:{layers:legacyLawLayers}});
    assert.deepEqual(independent.diagnostics,[],target);
    assert.deepEqual(evidence.after.files,manifest(independent),target);
  }
});


test('unestablished opaque-codec correspondence prevents canonical emission from becoming accepted evidence',async()=>{
  const input=request();
  input.sources=sources('unit parcel\ntype Parcel is | Packed last :: Bool first :: Bool end\ncopy :: Parcel -> Parcel');
  input.migrated.sources=sources('unit parcel\ntype Parcel is one of Packed of type record{last :: Bool first :: Bool} end type\ncopy :: Parcel -> Parcel');
  input.nativeBindings={types:[{type:'parcel::type::Parcel',native:['application','Parcel'],
    codec:{toNative:['application','encode'],fromNative:['application','decode']}}],
    functions:[{declaration:'parcel::copy',native:['application','copy']}]};
  const result=await compiler.migrationGeneration(input);assert.deepEqual(result.diagnostics,[]);
  const evidence=result.migrationGeneration;
  assert.equal(evidence.status,'not-established');assert.equal(evidence.before.status,'accepted');
  assert.equal(evidence.after.status,'not-established');
  assert.ok(evidence.bindingProposal.requirements.some(reason=>reason.includes('codec')));
  assert.equal(evidence.nativeConformance,'not-established');
});


test('API-level output directories stay scoped to that input and never become target defaults',async()=>{
  const report=await migrationReport(compiler,{version:1,targets:[{language:'python',root:'configured'}]},
    {target:'python',sourceDir:'input-app',testDir:'input-checks',nativeBindings:{},sources:sources(old)});
  assert.equal(report.generationPreview.status,'accepted',JSON.stringify(report.generationPreview));
  assert.equal(report.generationPreview.configurationCount,2);
  const configured=report.generationPreview.targets.find(row=>row.index===0);
  const input=report.generationPreview.targets.find(row=>row.index===null);
  assert.equal(configured.evidence.sourceDir,null);assert.equal(configured.evidence.testDir,null);
  assert.equal(input.evidence.sourceDir,'input-app');assert.equal(input.evidence.testDir,'input-checks');
  assert.ok(input.evidence.after.files.some(file=>file.path.startsWith('input-app/')));
  assert.ok(input.evidence.after.files.some(file=>file.path.startsWith('input-checks/')));
});
