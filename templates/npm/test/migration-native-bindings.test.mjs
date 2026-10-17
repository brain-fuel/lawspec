import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createCompiler} from '../api.mjs';
import {migrationReport} from '../migrate.mjs';
import {checkBindingProposal} from '../migration-bindings.mjs';
import {targets} from '../templates.mjs';
import {mkdtemp,readFile,writeFile,rm,stat} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {execFileSync,spawnSync} from 'node:child_process';

const compiler=await createCompiler();
const options={schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]}};
const old='unit bindings\ntype Flag is | FlagValue flag :: Bool end\ncopy :: Flag -> Flag';
const made='unit bindings\ntype Flag is one of | FlagValue of type Bool end type\ncopy :: Flag -> Flag';
const sources=content=>[{path:'bindings.lawspec',content}];
const bindings={types:[{type:'bindings::type::Flag',native:['application','Flag'],constructors:[
  {constructor:'FlagValue',native:['application','FlagValue'],style:'variant',fields:[{field:'flag',native:'stored'}]}]}],
  functions:[{declaration:'bindings::copy',native:['application','copy']}]};
const request=(target='python',machineBits=64)=>({...options,from:'0.24',target,machineBits,sources:sources(old),nativeBindings:bindings,
  migrated:{...options,machineBits,sources:sources(made)}});

async function propose(input=request()) {
  const result=await compiler.migrationBindings(input);
  assert.deepEqual(result.diagnostics,[],JSON.stringify(result));
  return result.migrationBindings;
}

test('single-payload proposals preserve actual native fields across every target and width',async()=>{
  for(const target of targets)for(const machineBits of [32,64]) {
    const evidence=await propose(request(target,machineBits));
    assert.equal(evidence.status,'matched',JSON.stringify(evidence));
    assert.equal(evidence.beforeValidated,true);
    assert.equal(evidence.afterValidated,true);
    assert.equal(evidence.target,target);
    assert.equal(evidence.machineBits,machineBits);
    assert.deepEqual(evidence.inputBindings,bindings);
    assert.deepEqual(evidence.proposedNativeBindings.types[0].constructors[0].fields,[{field:'value',native:'stored'}]);
    assert.deepEqual(evidence.proposedNativeBindings.functions,bindings.functions);
    assert.equal(evidence.nativeConformance,'not-established');
    assert.equal(evidence.targetGeneration,'not-established');
    assert.equal(evidence.lawVerification,'not-established-by-binding-correspondence');
    const checked=await compiler.check({...options,machineBits,sources:sources(made),nativeBindings:evidence.proposedNativeBindings});
    assert.deepEqual(checked.diagnostics,[]);
  }
});

test('a one-field message record preserves its explicit native argument across every target and width',async()=>{
  const previous='unit bindings\ntype Failure is | Declined message :: Text end\ncopy :: Failure -> Failure';
  const next='unit bindings\ntype Failure is one of | Declined of type record{message :: Text} end type\ncopy :: Failure -> Failure';
  const mapped={types:[{type:'bindings::type::Failure',native:['application','Failure'],constructors:[
    {constructor:'Declined',native:['application','Declined'],style:'variant',fields:[{field:'message',native:'reason'}]}]}],
    functions:[{declaration:'bindings::copy',native:['application','copy']}]};
  for(const target of targets)for(const machineBits of [32,64]) {
    const evidence=await propose({...options,from:'0.24',target,machineBits,sources:sources(previous),nativeBindings:mapped,
      migrated:{...options,machineBits,sources:sources(next)}});
    assert.equal(evidence.status,'matched',JSON.stringify(evidence));
    assert.deepEqual(evidence.proposedNativeBindings.types[0].constructors[0].fields,
      [{field:'value',native:'reason',path:['message'],argument:0}]);
    assert.equal(evidence.nativeConformance,'not-established');
    assert.equal(evidence.targetGeneration,'not-established');
  }
});

test('project reports check each actual target and expose explicit proposed binding changes',async()=>{
  const original={version:1,targets:[{language:'python',root:'python',nativeBindings:bindings},
    {language:'java',root:'java',nativeBindings:bindings},{language:'rust',root:'rust'}]};
  const snapshot=structuredClone(original);
  const report=await migrationReport(compiler,original,{sources:sources(old)});
  assert.deepEqual(original,snapshot);
  assert.deepEqual(report.diagnostics,[]);
  assert.equal(report.sourcePreview.canonicalCheck.status,'accepted');
  assert.equal(report.bindingPreview.status,'matched',JSON.stringify(report.bindingPreview));
  assert.equal(report.correspondence.nativeBindings.status,'matched');
  assert.equal(report.bindingPreview.configurationCount,3);
  assert.deepEqual(report.proposedConfiguration.targets[0].nativeBindings.types[0].constructors[0].fields,[{field:'value',native:'stored'}]);
  assert.equal(report.proposedConfiguration.targets[2].nativeBindings,undefined);
  assert.deepEqual(report.filesWritten,[]);
  assert.equal(report.validated,false);
  assert.equal(report.correspondence.generatedBehavior.status,'not-established');
  assert.ok(report.generationPreview.targets.some(row=>row.status!=='accepted'||row.nativeBoundary.status!=='matched'));
});

test('API-supplied legacy native bindings no longer enter the binding-blind schema-3 request',async()=>{
  const report=await migrationReport(compiler,{version:1,targets:[]},{sources:sources(old),nativeBindings:bindings});
  assert.deepEqual(report.diagnostics,[]);
  assert.equal(report.bindingPreview.configurationCount,1);
  assert.equal(report.bindingPreview.targets[0].status,'matched',JSON.stringify(report.bindingPreview));
  assert.equal(report.bindingPreview.targets[0].index,null);
  assert.deepEqual(report.bindingPreview.targets[0].proposedNativeBindings.types[0].constructors[0].fields,[{field:'value',native:'stored'}]);
});

test('grouped native payloads derive a checked layout preserving original argument positions',async()=>{
  const content='unit bindings\ntype Pair is | Packed last :: Bool first :: Bool end\ncopy :: Pair -> Pair';
  const mapped={types:[{type:'bindings::type::Pair',native:['application','Pair'],constructors:[
    {constructor:'Packed',native:['application','Packed'],style:'variant',fields:[{field:'first',native:'left'},{field:'last',native:'right'}]}]}],
    functions:bindings.functions};
  const config={version:1,targets:[{language:'python',root:'python',nativeBindings:mapped}]};
  const report=await migrationReport(compiler,config,{sources:sources(content)});
  assert.equal(report.sourcePreview.canonicalCheck.status,'accepted');
  const row=report.bindingPreview.targets[0];
  assert.equal(row.status,'matched',JSON.stringify(row));
  assert.equal(row.evidence.proposalComplete,true);
  assert.deepEqual(row.evidence.requirements,[]);
  assert.equal(row.evidence.changes[0].kind,'grouped-record-payload');
  assert.deepEqual(row.evidence.changes[0].fields,[
    {field:'last',native:'right',nativeArgumentIndex:0,payloadPath:['value','last']},
    {field:'first',native:'left',nativeArgumentIndex:1,payloadPath:['value','first']},
  ]);
  assert.deepEqual(report.proposedConfiguration.targets[0].nativeBindings.types[0].constructors[0].fields,[
    {field:'value',path:['last'],argument:0,native:'right'},
    {field:'value',path:['first'],argument:1,native:'left'},
  ]);
  assert.equal(row.evidence.nativeConformance,'not-established');
  assert.equal(row.evidence.targetGeneration,'not-established');
  assert.equal(report.validated,true);
});

test('opaque codecs and factories over changed generated representations remain unresolved',async()=>{
  const codec={types:[{type:'bindings::type::Flag',native:['application','Flag'],codec:{toNative:['application','encode'],fromNative:['application','decode']}}],functions:bindings.functions};
  const unknownCodec=await propose({...request(),nativeBindings:codec});
  assert.equal(unknownCodec.status,'not-established');
  assert.equal(unknownCodec.afterValidated,true);
  assert.equal(unknownCodec.bindings.status,'matched');
  assert.equal(unknownCodec.obligations.status,'matched');
  assert.match(unknownCodec.requirements.join(' '),/codec.*implementation needs independent correspondence checks/);
  const factory=await propose({...request(),nativeBindings:{functions:bindings.functions,generators:[{type:'bindings::type::Flag',factory:['application','flags']}]}});
  assert.equal(factory.status,'not-established');
  assert.match(factory.requirements.join(' '),/generator.*changed generated representation/);
  assert.match(factory.requirements.join(' '),/native function.*without a corresponding native type binding/);
  const unchanged=await propose({...request(),nativeBindings:codec,
    sources:sources('unit bindings\ntype Flag is Flag flag :: Bool end\ncopy :: Flag -> Flag'),
    migrated:{...options,sources:sources('unit bindings\ntype Flag is a record{flag :: Bool} end type\ncopy :: Flag -> Flag')}});
  assert.equal(unchanged.status,'matched',JSON.stringify(unchanged));
  assert.equal(unchanged.nativeConformance,'not-established');
});

test('changed native choices and invalid explicit destinations cannot match an automatic proposal',async()=>{
  const automatic=await propose();
  const changed=structuredClone(automatic.proposedNativeBindings);
  changed.types[0].constructors[0].fields[0].native='other';
  const evidence=await propose({...request(),migrated:{...request().migrated,nativeBindings:changed}});
  assert.equal(evidence.status,'not-established');
  assert.equal(evidence.afterValidated,true);
  assert.match(evidence.requirements.join(' '),/differ from the checked automatic proposal/);
  const invalid=structuredClone(changed);
  invalid.types[0].constructors[0].fields[0].field='flag';
  const refused=await propose({...request(),migrated:{...request().migrated,nativeBindings:invalid}});
  assert.equal(refused.status,'unavailable');
  assert.match(refused.reason,/fields/);
});

test('a binding error in one target blocks project binding correspondence independently of other targets',async()=>{
  const invalid=structuredClone(bindings);invalid.types[0].constructors[0].fields[0].field='missing';
  const report=await migrationReport(compiler,{version:1,targets:[
    {language:'python',root:'python',nativeBindings:bindings},{language:'java',root:'java',nativeBindings:invalid}]},
    {sources:sources(old)});
  assert.equal(report.bindingPreview.status,'not-established');
  assert.equal(report.bindingPreview.targets[0].status,'matched');
  assert.equal(report.bindingPreview.targets[1].status,'not-established');
  assert.ok(report.bindingPreview.targets[1].diagnostics.some(item=>item.code==='native-binding'));
  assert.ok(report.blockers.some(reason=>reason.includes('Native bindings for java')));
  assert.deepEqual(report.filesWritten,[]);
});

test('stale, cross-target, changed-input and incomplete binding facts cannot discharge the host gate',async()=>{
  const baseline=await compiler.migrationBaseline({...options,from:'0.24',sources:sources(old)});
  const destination=await compiler.check({...options,migrationSnapshot:true,sources:sources(made)});
  const evidence=await propose();
  const check=value=>checkBindingProposal(baseline.migrationSemantics,destination.migrationSemantics,bindings,'python',value);
  assert.equal(check(evidence).status,'matched');
  for(const mutate of [
    value=>{value.version=2;},value=>{value.machineBits=32;},value=>{value.target='java';},
    value=>{value.inputBindings.types[0].native=['other','Flag'];},
    value=>{value.before.programDigest='0'.repeat(64);},
    value=>{value.sourceTemplates.after.lawTemplatesDigest='0'.repeat(64);},
    value=>{value.afterValidated=false;},value=>{value.proposalComplete=false;},
    value=>{value.bindings.after='0'.repeat(64);},value=>{value.requirements=['unresolved'];},
    value=>{value.originalBindingsDigest='invalid';},
    value=>{value.proposedNativeBindings.types[0].constructors[0].fields[0].native='changed';},
    value=>{value.nativeConformance='proved';},value=>{value.targetGeneration='matched';},
    value=>{value.obligations.after[0].status='proved';},
    value=>{for(const side of ['before','after'])value.obligations[side][0].status='proved';},
  ]) {const copy=structuredClone(evidence);mutate(copy);assert.equal(check(copy).status,'not-established');}
});

test('binding proposals retain mandatory admission, matching widths and empty law-layer selections',async()=>{
  for(const input of [
    {...request(),machineBits:32},
    {...request(),verification:{layers:['proof']}},
    {...request(),migrated:{...request().migrated,verification:{layers:['examples']}}},
    {...request(),nativeBindings:{},sources:sources('unit bindings\ndefinition invalid (value :: Integer) :: Integer is 1 / value end')},
  ]) {
    const result=await compiler.migrationBindings(input);
    assert.ok(result.diagnostics.length,JSON.stringify(result));
    assert.equal(result.migrationBindings,undefined);
  }
});


test('CLI previews bound projects without changing sources, configuration or application roots',async t=>{
  const directory=await mkdtemp(path.join(tmpdir(),'lawspec-binding-migration-'));
  t.after(()=>rm(directory,{recursive:true,force:true}));
  const config=JSON.stringify({version:1,sources:['bindings.lawspec'],targets:[
    {language:'python',root:'python',nativeBindings:bindings}]},null,2)+'\n';
  await writeFile(path.join(directory,'lawspec.json'),config);
  await writeFile(path.join(directory,'bindings.lawspec'),old);
  const cli=new URL('../bin/lawspec.mjs',import.meta.url).pathname;
  const run=args=>execFileSync(process.execPath,[cli,'migrate','--from','0.24',...args],{cwd:directory,encoding:'utf8',maxBuffer:32*1024*1024});
  const report=JSON.parse(run(['--json']));
  assert.equal(report.bindingPreview.status,'matched');
  assert.deepEqual(report.filesWritten,[]);
  assert.match(run([]),/Native binding preview: 1 of 1 original configurations checked; 1 proposals match; 1 field changes/);
  assert.equal(await readFile(path.join(directory,'lawspec.json'),'utf8'),config);
  assert.equal(await readFile(path.join(directory,'bindings.lawspec'),'utf8'),old);
  const written=spawnSync(process.execPath,[cli,'migrate','--from','0.24','--write','--json'],{cwd:directory,encoding:'utf8'});
  assert.equal(written.status,0,written.stdout+written.stderr);
  assert.equal(JSON.parse(written.stdout).validated,true);
  const made=JSON.parse(await readFile(path.join(directory,'lawspec.json'),'utf8'));
  assert.equal(made.version,2);
  assert.deepEqual(made.targets[0].nativeBindings.types[0].constructors[0].fields,[{field:'value',native:'stored'}]);
  assert.equal(await readFile(path.join(directory,'bindings.lawspec'),'utf8'),report.sourcePreview.sources[0].content);
  await assert.rejects(stat(path.join(directory,'python')),error=>error.code==='ENOENT');
});


test('one-off API bindings do not replace an actual target configuration or become implicit target defaults',async()=>{
  const config={version:1,targets:[{language:'python',root:'python',nativeBindings:null},{language:'java',root:'java'}]};
  const report=await migrationReport(compiler,config,{sources:sources(old),nativeBindings:bindings});
  assert.equal(report.bindingPreview.status,'matched',JSON.stringify(report.bindingPreview));
  assert.equal(report.bindingPreview.configurationCount,3);
  assert.deepEqual(report.bindingPreview.targets.filter(row=>row.index!==null).map(row=>row.evidence.inputBindings),[{},{}]);
  assert.deepEqual(report.proposedConfiguration.targets[0].nativeBindings.types,[]);
  assert.equal(report.proposedConfiguration.targets[1].nativeBindings,undefined);
  const input=report.bindingPreview.targets.find(row=>row.index===null);
  assert.deepEqual(input.evidence.inputBindings,bindings);
  assert.deepEqual(input.proposedNativeBindings.types[0].constructors[0].fields,[{field:'value',native:'stored'}]);
  assert.deepEqual(config.targets[0].nativeBindings,null);
});
