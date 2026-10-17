// Generated from templates/npm/test/migration-correspondence.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';
import {migrationReport} from '../migrate.mjs';
import {compareMigrationSnapshots} from '../migration-correspondence.mjs';

const snapshot={status:'available',version:1,algorithm:'sha256',machineBits:64,
  programDigest:'0'.repeat(64),definitionPlaneDigest:'1'.repeat(64),lawBodiesDigest:'2'.repeat(64),
  definitions:[],contracts:[],dataTypes:[],
  domainPolicies:[{comparisonId:'unit::law::same',policy:'nonempty'}]};

const templates={status:'available',version:1,algorithm:'sha256',machineBits:64,
  declarationsDigest:'3'.repeat(64),definitionTemplatesDigest:'4'.repeat(64),lawTemplatesDigest:'5'.repeat(64),lawBodiesDigest:'6'.repeat(64),
  units:[],definitions:[],laws:[],domainPolicies:[]};

const domain={comparisonId:'unit::law::same',domainDigest:'a'.repeat(64),inputCount:1,status:'inhabited',
  witness:[{binder:'unit::law::same::bound::0',value:{type:'Bool',value:false}}]};
const domainSnapshot=entry=>({status:'available',version:1,algorithm:'sha256',machineBits:64,lawBodiesEvaluated:false,domains:[entry]});

test('matching complete Core bodies and verified domains establish Core correspondence without verifying laws',()=>{
  const before={...snapshot,inputDomains:domainSnapshot(domain)};
  const after={...snapshot,programDigest:'b'.repeat(64),domainPolicies:[{comparisonId:'unit::law::same',policy:'universal'}],
    inputDomains:domainSnapshot(domain)};
  const compared=compareMigrationSnapshots(before,after);
  assert.equal(compared.domainPolicies.status,'matched');
  assert.equal(compared.domainPolicies.domains[0].basis,'matching-domain-dependencies-and-verified-input-witnesses');
  assert.equal(compared.domainPolicies.lawVerification,'not-established-by-domain-evidence');
  assert.equal(compared.program.status,'matched');
  assert.equal(compared.program.basis,'matching-policy-erased-complete-Core-and-verified-input-domains');
  assert.equal(compared.status,'not-established');
});

test('different nominal or predicate dependencies cannot share an input-domain certificate',()=>{
  const before={...snapshot,inputDomains:domainSnapshot(domain)};
  const after={...snapshot,domainPolicies:[{comparisonId:'unit::law::same',policy:'universal'}],
    inputDomains:domainSnapshot({...domain,domainDigest:'b'.repeat(64)})};
  assert.equal(compareMigrationSnapshots(before,after).domainPolicies.status,'not-established');
});

test('empty, incomplete, unsupported and malformed input evidence never clears a changed policy',()=>{
  for(const evidence of [undefined,{...domainSnapshot(domain),version:2},{...domainSnapshot(domain),machineBits:32},
    {...domainSnapshot(domain),lawBodiesEvaluated:true},domainSnapshot({...domain,status:'empty',complete:true,witness:undefined}),
    domainSnapshot({...domain,status:'incomplete'}),domainSnapshot({...domain,status:'unsupported'}),
    domainSnapshot({...domain,witness:[]}),domainSnapshot({...domain,inputCount:undefined})]) {
    const before={...snapshot,inputDomains:domainSnapshot(domain)};
    const after={...snapshot,domainPolicies:[{comparisonId:'unit::law::same',policy:'universal'}],inputDomains:evidence};
    assert.equal(compareMigrationSnapshots(before,after).domainPolicies.status,'not-established');
  }
});

test('matching checked source templates remain separate from native binding and behavior correspondence',()=>{
  const compared=compareMigrationSnapshots({...snapshot,sourceTemplates:templates},{...snapshot,sourceTemplates:templates});
  assert.equal(compared.sourceTemplates.status,'matched');
  assert.equal(compared.sourceTemplates.definitions.basis,'matching-checked-source-template-fingerprints');
  assert.equal(compared.nativeBindings.status,'not-established');
  assert.equal(compared.generatedBehavior.status,'not-established');
  assert.equal(compared.status,'not-established');
});

test('an unused template change cannot disappear behind matching concrete Core fingerprints',()=>{
  const before={...templates,definitions:[{comparisonId:'unit::pick',digest:'7'.repeat(64)}]};
  const after={...before,definitionTemplatesDigest:'8'.repeat(64),definitions:[{comparisonId:'unit::pick',digest:'9'.repeat(64)}]};
  const compared=compareMigrationSnapshots({...snapshot,sourceTemplates:before},{...snapshot,sourceTemplates:after});
  assert.equal(compared.program.status,'matched');
  assert.equal(compared.sourceTemplates.status,'not-established');
  assert.equal(compared.sourceTemplates.definitions.status,'not-established');
  assert.deepEqual(compared.sourceTemplates.differences.definitions.changed,['unit::pick']);
});

test('template law-body matches cannot discharge changed domain policies',()=>{
  const before={...templates,domainPolicies:[{comparisonId:'unit::law::unused',policy:'nonempty'}]};
  const after={...before,lawTemplatesDigest:'7'.repeat(64),domainPolicies:[{comparisonId:'unit::law::unused',policy:'universal'}]};
  const compared=compareMigrationSnapshots({...snapshot,sourceTemplates:before},{...snapshot,sourceTemplates:after});
  assert.equal(compared.sourceTemplates.lawBodies.status,'matched');
  assert.equal(compared.sourceTemplates.lawBodies.includesDomainPolicy,false);
  assert.equal(compared.sourceTemplates.domainPolicies.status,'not-established');
  assert.equal(compared.sourceTemplates.status,'not-established');
});

test('absent, malformed and unsupported template snapshots cannot be accepted as correspondence',()=>{
  for(const after of [undefined,null,{...templates,version:2},{...templates,machineBits:32},
    {...templates,definitionTemplatesDigest:undefined},{...templates,definitions:[null]},
    {...templates,domainPolicies:[{comparisonId:'law',policy:'unchecked'}]}]) {
    const compared=compareMigrationSnapshots({...snapshot,sourceTemplates:templates},{...snapshot,sourceTemplates:after});
    assert.equal(compared.sourceTemplates.status,'not-established');
  }
  const unknown=compareMigrationSnapshots({sourceTemplates:{...templates,machineBits:undefined}},
    {sourceTemplates:{...templates,machineBits:undefined}});
  assert.equal(unknown.sourceTemplates.status,'not-established');
});

test('matching concrete fingerprints never claim full migration or law verification',()=>{
  const compared=compareMigrationSnapshots(snapshot,snapshot);
  for(const name of ['program','definitionPlane','lawBodies','domainPolicies']) assert.equal(compared[name].status,'matched');
  for(const name of ['sourceTemplates','nativeBindings','generatedBehavior']) assert.equal(compared[name].status,'not-established');
  assert.equal(compared.status,'not-established');
  assert.equal(compared.lawBodies.includesDomainPolicy,false);
});

test('matching law-body fingerprints never erase a nonempty-to-universal domain change',()=>{
  const compared=compareMigrationSnapshots(snapshot,{...snapshot,programDigest:'3'.repeat(64),
    domainPolicies:[{comparisonId:'unit::law::same',policy:'universal'}]});
  assert.equal(compared.definitionPlane.status,'matched');
  assert.equal(compared.lawBodies.status,'matched');
  assert.equal(compared.domainPolicies.status,'not-established');
  assert.equal(compared.program.status,'not-established');
  assert.match(compared.domainPolicies.reason,/inhabitance/);
});

test('different complete-Core fingerprints are reported as unestablished rather than proof of inequivalence',()=>{
  const compared=compareMigrationSnapshots(snapshot,{...snapshot,definitionPlaneDigest:'4'.repeat(64)});
  assert.equal(compared.definitionPlane.status,'not-established');
  assert.match(compared.definitionPlane.reason,/correspondence has not been established/);
});

test('part fingerprints identify changed, added and removed checked identities without ignoring nominal metadata',()=>{
  const before={...snapshot,definitions:[{comparisonId:'unit::function',digest:'3'.repeat(64)}],
    dataTypes:[{comparisonId:'unit::Old',digest:'4'.repeat(64)}]};
  const after={...snapshot,definitions:[{comparisonId:'unit::function',digest:'5'.repeat(64)}],
    dataTypes:[{comparisonId:'unit::New',digest:'6'.repeat(64)}]};
  const compared=compareMigrationSnapshots(before,after);
  assert.deepEqual(compared.differences.definitions,{added:[],removed:[],changed:['unit::function']});
  assert.deepEqual(compared.differences.dataTypes,{added:['unit::New'],removed:['unit::Old'],changed:[]});
});

test('missing, unsupported, malformed and cross-width snapshots cannot match by absent fields',()=>{
  for(const after of [undefined,{status:'unavailable'}, {...snapshot,status:'available',version:2},
    {...snapshot,algorithm:'unknown'},{...snapshot,machineBits:32},{...snapshot,programDigest:undefined},
    {...snapshot,programDigest:'not a digest'},{...snapshot,domainPolicies:[{comparisonId:'law',policy:'unchecked'}]},
    {...snapshot,definitions:[null]},{...snapshot,domainPolicies:[null]},
    {...snapshot,domainPolicies:[...snapshot.domainPolicies,...snapshot.domainPolicies]}]) {
    const compared=compareMigrationSnapshots(snapshot,after);
    assert.equal(compared.program.status,'not-established');
    assert.equal(compared.definitionPlane.status,'not-established');
    assert.equal(compared.lawBodies.status,'not-established');
  }
});

const compiler=await createCompiler();
const options={schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]}};

test('actual compiler snapshots compare migrated computation and preserve the no-selected-checks state',async()=>{
  for(const machineBits of [32,64]) {
    const sources=[{path:'same.lawspec',content:'unit same\ndefinition same (value :: Bool) :: Bool is value end'}];
    const report=await migrationReport(compiler,{version:1,targets:[]},{sources,machineBits});
    assert.deepEqual(report.diagnostics,[]);
    assert.equal(report.sourcePreview.canonicalCheck.status,'accepted');
    assert.equal(report.sourcePreview.canonicalCheck.intrinsicDefinitionChecks,true);
    assert.equal(report.sourcePreview.canonicalCheck.lawVerification,'no-selected-checks');
    assert.equal(report.baseline.coreSnapshot.status,'available');
    assert.equal(report.baseline.coreSnapshot.machineBits,machineBits);
    assert.equal(report.correspondence.program.status,'matched');
    assert.equal(report.correspondence.definitionPlane.status,'matched');
    assert.deepEqual(report.correspondence.differences.definitions,{added:[],removed:[],changed:[]});
    assert.equal(report.correspondence.status,'matched-under-existing-assumptions');
    assert.equal(report.validated,true,JSON.stringify(report.blockers));
    assert.deepEqual(report.filesWritten,[]);
    const canonical={...options,machineBits,sources:report.sourcePreview.sources.map(({path,content})=>({path,content}))};
    const ordinary=await compiler.check(canonical);
    assert.equal(ordinary.migrationSemantics,undefined);
    const requested=await compiler.check({...canonical,migrationSnapshot:true});
    assert.deepEqual(requested.migrationSemantics,report.sourcePreview.canonicalCheck.coreSnapshot);
    assert.deepEqual(await compiler.check(canonical),ordinary,'A warm cache must not leak requested metadata');
    const mutated=await compiler.check({...canonical,migrationSnapshot:true,
      sources:canonical.sources.map(source=>({...source,content:source.content.replace('is value','is not value')}))});
    assert.deepEqual(mutated.diagnostics,[]);
    const compared=compareMigrationSnapshots(report.baseline.coreSnapshot,mutated.migrationSemantics);
    assert.equal(compared.definitionPlane.status,'not-established');
    assert.deepEqual(compared.differences.definitions.changed,['same::same']);
  }
});

test('actual verified input witnesses keep populated policy correspondence separate from law verification',async()=>{
  const sources=[{path:'law.lawspec',content:'unit domain\nlaw `same` is definition is `for all` (value :: Bool) . value = value end end'}];
  const report=await migrationReport(compiler,{version:1,targets:[]},{sources});
  assert.equal(report.sourcePreview.canonicalCheck.status,'accepted');
  assert.equal(report.correspondence.definitionPlane.status,'matched');
  assert.equal(report.correspondence.lawBodies.status,'matched');
  assert.equal(report.correspondence.domainPolicies.status,'matched');
  assert.equal(report.correspondence.domainPolicies.lawVerification,'not-established-by-domain-evidence');
  assert.equal(report.correspondence.program.status,'matched');
  assert.deepEqual(report.correspondence.domainPolicies.before,[{comparisonId:'domain::law::same',policy:'nonempty'}]);
  assert.deepEqual(report.correspondence.domainPolicies.after,[{comparisonId:'domain::law::same',policy:'universal'}]);
  assert.equal(report.baseline.coreSnapshot.inputDomains.domains[0].status,'inhabited');
  assert.equal(report.sourcePreview.canonicalCheck.coreSnapshot.inputDomains.domains[0].status,'inhabited');
});

test('actual nominal restrictions and GADT equations participate in full-Core fingerprints',async()=>{
  for(const [before,after] of [
    ['type Pair is Pair first :: UInt8 second :: (value :: UInt8 where value >= first) end',
     'type Pair is Pair first :: UInt8 second :: (value :: UInt8 where value > first) end'],
    ['type Term (a :: Type) is | Number value :: Integer where a = Integer end',
     'type Term (a :: Type) is | Number value :: Integer where a = Bool end'],
  ]) {
    const compile=async content=>{
      const result=await compiler.migrationBaseline({...options,from:'0.24',sources:[{path:'type.lawspec',content:'unit types\n'+content}]});
      assert.deepEqual(result.diagnostics,[]);
      return result.migrationSemantics;
    };
    const compared=compareMigrationSnapshots(await compile(before),await compile(after));
    assert.equal(compared.definitionPlane.status,'not-established');
    assert.equal(compared.differences.dataTypes.changed.length,1);
  }
});

test('Chapter 6 retains raw shape differences while establishing transported Core and input domains at both widths',async()=>{
  const content=await readFile(new URL('../../test/fixtures/migration-chap06-0.24.lawspec',import.meta.url),'utf8');
  for(const machineBits of [32,64]) {
  const report=await migrationReport(compiler,{version:1,targets:[]},{machineBits,sources:[{path:'chap06.lawspec',content}]});
  assert.equal(report.sourcePreview.canonicalCheck.status,'accepted');
  assert.equal(report.correspondence.program.status,'matched');
  assert.equal(report.correspondence.program.basis,'matching-complete-Core-after-validated-payload-transport-and-input-domain-correspondence');
  assert.equal(report.correspondence.nativeBindings.status,'matched');
  assert.equal(report.correspondence.nativeBindings.configurationCount,0);
  assert.deepEqual(report.correspondence.differences.dataTypes.changed,['nand2tetris.chap06::type::Predefined','nand2tetris.chap06::type::Line']);
  assert.equal(report.correspondence.differences.dataTypes.added.length,1);
  assert.ok(report.correspondence.differences.dataTypes.added[0].startsWith('lawspec::structural::record::'));
  assert.equal(report.correspondence.differences.definitions.changed.length,8);
  assert.equal(report.correspondence.domainPolicies.before.length,23);
  assert.equal(report.correspondence.domainPolicies.status,'matched');
  for(const snapshot of [report.baseline.coreSnapshot,report.sourcePreview.canonicalCheck.coreSnapshot]) {
    assert.equal(snapshot.inputDomains.domains.length,23);
    assert.ok(snapshot.inputDomains.domains.every(domain=>domain.status==='inhabited'));
  }
  assert.equal(report.correspondence.domainPolicies.domains.filter(domain=>domain.status==='matched').length,23);
  assert.equal(report.correspondence.domainPolicies.domains.filter(domain=>domain.valueRepresentation==='transported-before-and-canonical-after').length,6);
  assert.equal(report.correspondence.domainPolicies.lawVerification,'not-established-by-domain-evidence');
  assert.equal(report.validated,true,JSON.stringify(report.blockers));
  assert.deepEqual(report.filesWritten,[]);
  }
});

test('explicit snapshot capture cannot bypass mandatory definition checks or accept a malformed request',async()=>{
  const sources=[{path:'invalid.lawspec',content:'unit invalid\nfunction unsafe (value :: Integer) -> Integer is 1 / value end function'}];
  const rejected=await compiler.check({...options,migrationSnapshot:true,sources});
  assert.ok(rejected.diagnostics.length);
  assert.equal(rejected.migrationSemantics,undefined);
  for(const schemaVersion of [3,4]) {
    const invalid=await compiler.check({schemaVersion,migrationSnapshot:true,sources:[]});
    assert.ok(invalid.diagnostics.length);
  }
  const malformed=await compiler.check({...options,migrationSnapshot:'yes',sources:[]});
  assert.ok(malformed.diagnostics.length);
});

test('actual unused generic bodies and capability requirements survive concrete specialization',async()=>{
  const original='unit unused\ndefinition pick (left :: a) (right :: a) :: a requires Eq a is left end';
  const capture=async content=>{
    const result=await compiler.migrationBaseline({...options,from:'0.24',sources:[{path:'unused.lawspec',content}]});
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.migrationSemantics.sourceTemplates.status,'available');
    return result.migrationSemantics;
  };
  for(const changed of [original.replace('is left','is right'),original.replace('requires Eq','requires Keyed')]) {
    const before=await capture(original),after=await capture(changed);
    assert.equal(before.programDigest,after.programDigest,'Unused templates have no concrete implementation');
    const compared=compareMigrationSnapshots(before,after);
    assert.equal(compared.program.status,'matched');
    assert.equal(compared.sourceTemplates.definitions.status,'not-established');
    assert.deepEqual(compared.sourceTemplates.differences.definitions.changed,['unused::pick']);
  }
});

test('actual unused reusable-law requirements survive concrete law filtering',async()=>{
  const original='unit unused\nlaw `preserved` (operation :: a -> a) requires Eq a is '+
    'definition is `for all` (value :: a) . operation value = value end end';
  const capture=async content=>{
    const result=await compiler.migrationBaseline({...options,from:'0.24',sources:[{path:'unused-law.lawspec',content}]});
    assert.deepEqual(result.diagnostics,[]);
    return result.migrationSemantics;
  };
  const before=await capture(original),after=await capture(original.replace('operation value = value','value = value'));
  assert.equal(before.programDigest,after.programDigest);
  const compared=compareMigrationSnapshots(before,after);
  assert.equal(compared.sourceTemplates.status,'not-established');
  assert.equal(compared.sourceTemplates.laws.status,'not-established');
  assert.deepEqual(compared.sourceTemplates.differences.laws.changed,['unused::law::preserved']);
});

test('actual input-domain evidence distinguishes finite emptiness, bounded misses and unverified law bodies',async()=>{
  const capture=async definition=>{
    const result=await compiler.check({...options,migrationSnapshot:true,sources:[{path:'domain.lawspec',
      content:'unit domain\nlaw requirement is definition: '+definition+' end end'}]});
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.evidence.find(item=>item.stage==='law').status,'not-verified');
    assert.equal(result.migrationSemantics.inputDomains.lawBodiesEvaluated,false);
    return result.migrationSemantics.inputDomains.domains[0];
  };
  const populated=await capture('for all (value :: Bool) => false end');
  assert.equal(populated.status,'inhabited');
  assert.deepEqual(populated.witness[0].value,{type:'Bool',value:false});
  const empty=await capture('for all (value :: Bool where false) => true end');
  assert.equal(empty.status,'empty');
  assert.equal(empty.complete,true);
  assert.equal(empty.witness,undefined);
  const missed=await capture('for all (value :: Integer where value * value = 1040400) => true end');
  assert.equal(missed.status,'incomplete');
  assert.equal(missed.complete,false);
  assert.equal(missed.witness,undefined);
});

test('actual changed checked predicates invalidate matching-looking domain names',async()=>{
  const old='unit domain\ndefinition allowed (value :: Bool) :: Bool is value end\n'+
    'law `same` is definition is `for all` (value :: Bool where allowed value) . value = value end end';
  const before=await compiler.migrationBaseline({...options,from:'0.24',sources:[{path:'before.lawspec',content:old}]});
  const after=await compiler.check({...options,migrationSnapshot:true,sources:[{path:'after.lawspec',content:
    'unit domain\nfunction allowed (value :: Bool) -> Bool is not value end function\n'+
    'law "|same| is definition: for all (value :: Bool where allowed value) => value = value end end end'}]});
  for(const result of [before,after]) {
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.migrationSemantics.inputDomains.domains[0].status,'inhabited');
  }
  assert.notEqual(before.migrationSemantics.inputDomains.domains[0].domainDigest,after.migrationSemantics.inputDomains.domains[0].domainDigest);
  assert.equal(compareMigrationSnapshots(before.migrationSemantics,after.migrationSemantics).domainPolicies.status,'not-established');
});


const templateAnchors=value=>Object.fromEntries(
  ['declarationsDigest','definitionTemplatesDigest','lawTemplatesDigest','lawBodiesDigest'].map(key=>[key,value[key]]));
function templatePair() {
  const before={...templates,domainPolicies:[{comparisonId:domain.comparisonId,policy:'nonempty'}]};
  const after={...before,lawTemplatesDigest:'7'.repeat(64),domainPolicies:[{comparisonId:domain.comparisonId,policy:'universal'}]};
  for(const value of [before,after]) value.inputDomains={...domainSnapshot(domain),sourceTemplates:templateAnchors(value)};
  return [before,after];
}
const templateComparison=(before,after)=>compareMigrationSnapshots(
  {...snapshot,machineBits:before.machineBits,sourceTemplates:before},
  {...snapshot,machineBits:after.machineBits,sourceTemplates:after}).sourceTemplates;

test('uniform source-template input evidence clears population policy without claiming law verification',()=>{
  const [before,after]=templatePair(),compared=templateComparison(before,after);
  assert.equal(compared.domainPolicies.status,'matched');
  assert.equal(compared.domainPolicies.domains[0].status,'matched');
  assert.equal(compared.domainPolicies.lawVerification,'not-established-by-domain-evidence');
  assert.equal(compared.laws.status,'matched');
  assert.equal(compared.status,'matched');
  const complete=compareMigrationSnapshots({...snapshot,sourceTemplates:before},{...snapshot,sourceTemplates:after});
  for(const key of ['status','nativeBindings','generatedBehavior']) {
    assert.equal(key==='status'?complete[key]:complete[key].status,'not-established');
  }
});

test('source-template evidence cannot be transplanted across captures or widths',()=>{
  const [before,after]=templatePair();
  const evidence=after.inputDomains;
  const invalid=[undefined,domainSnapshot(domain),{...evidence,sourceTemplates:templateAnchors(before)},
    {...evidence,version:2},{...evidence,machineBits:32},{...evidence,lawBodiesEvaluated:true},
    {...evidence,domains:[domain,domain]},
    ...Object.keys(templateAnchors(after)).map(key=>({...evidence,sourceTemplates:{...evidence.sourceTemplates,[key]:'f'.repeat(64)}}))];
  for(const inputDomains of invalid) {
    assert.equal(templateComparison(before,{...after,inputDomains}).domainPolicies.status,'not-established');
  }
});

test('generic, empty, incomplete or parameter-dependent source domains cannot clear a policy change',()=>{
  const [before,after]=templatePair();
  for(const row of [{...domain,status:'unsupported',witness:undefined,complete:false},
    {...domain,status:'incomplete',witness:undefined,complete:false},
    {...domain,status:'empty',witness:undefined,complete:true},
    {...domain,domainDigest:'f'.repeat(64)},{...domain,inputCount:2},{...domain,witness:[]}]) {
    const compared=templateComparison(before,{...after,inputDomains:{...after.inputDomains,domains:[row]}});
    assert.equal(compared.domainPolicies.status,'not-established');
    assert.equal(compared.laws.status,'not-established');
  }
});

test('domain evidence never hides a changed source body or unused definition',()=>{
  const [before,after]=templatePair();
  for(const key of ['lawBodiesDigest','definitionTemplatesDigest','declarationsDigest']) {
    const changed={...after,[key]:'f'.repeat(64)};
    changed.inputDomains={...after.inputDomains,sourceTemplates:templateAnchors(changed)};
    assert.equal(templateComparison(before,changed).status,'not-established');
  }
});

test('actual reusable source domains report uniform, dependent and generic limits at both widths',async()=>{
  for(const machineBits of [32,64]) {
    const oldClaim='`for all` (value :: Bool) . operation value = value';
    const newClaim='for all (value :: Bool) => operation value must be value end';
    const oldSource='unit uniform\nlaw `domain` (operation :: Bool -> Bool) is definition is '+oldClaim+' end end';
    const newSource='unit uniform\nlaw \"|domain| (operation :: Bool -> Bool) is definition: '+newClaim+' end end';
    const old=await compiler.migrationBaseline({...options,machineBits,from:'0.24',sources:[{path:'uniform.lawspec',content:oldSource}]});
    const next=await compiler.check({...options,machineBits,migrationSnapshot:true,sources:[{path:'uniform.lawspec',content:newSource}]});
    for(const result of [old,next]) assert.deepEqual(result.diagnostics,[]);
    const a=old.migrationSemantics.sourceTemplates,b=next.migrationSemantics.sourceTemplates;
    for(const value of [a,b]) {
      assert.equal(value.inputDomains.lawBodiesEvaluated,false);
      assert.deepEqual(value.inputDomains.sourceTemplates,templateAnchors(value));
      assert.equal(value.inputDomains.domains.length,value.laws.length);
      assert.equal(value.inputDomains.domains.find(row=>row.comparisonId==='uniform::law::domain').status,'inhabited');
    }
    const compared=templateComparison(a,b);
    assert.equal(compared.domainPolicies.domains.find(row=>row.comparisonId==='uniform::law::domain').status,'matched');
    // Versioned prelude policies are unchanged. Their unsupported domains
    // remain visible without requiring or assuming a uniform inhabitant.
    assert.equal(compared.status,'matched');
    assert.ok(a.inputDomains.domains.some(row=>row.comparisonId.startsWith('prelude::law::')&&row.status==='unsupported'));
    assert.ok(compared.domainPolicies.domains.every(row=>row.status==='matched'));
    assert.deepEqual(a.domainPolicies.filter(row=>row.comparisonId.startsWith('prelude::law::')),
      b.domainPolicies.filter(row=>row.comparisonId.startsWith('prelude::law::')));
    assert.equal(old.migrationSemantics.domainPolicies.length,0);
    for(const [content,expected] of [
      [newSource.replace('(operation :: Bool -> Bool)','(required :: Bool)').replace('(value :: Bool)','(value :: Bool where required)').replace('operation value must be value','true'),'unsupported'],
      [newSource.replace('(operation :: Bool -> Bool)','(operation :: a -> a) requires Eq a').replace('(value :: Bool)','(value :: a)'),'unsupported'],
      [newSource.replace('(value :: Bool)','(value :: Bool where false)'),'empty'],
      [newSource.replace('(value :: Bool)','(value :: Integer where value * value = -1)').replace('operation value must be value','false'),'incomplete'],
      [newSource.replace('operation value must be value','(1 / 0 :: Integer) = 0'),'inhabited'],
    ]) {
      const result=await compiler.check({...options,machineBits,migrationSnapshot:true,sources:[{path:'uniform.lawspec',content}]});
      assert.deepEqual(result.diagnostics,[]);
      const row=result.migrationSemantics.sourceTemplates.inputDomains.domains.find(row=>row.comparisonId==='uniform::law::domain');
      assert.equal(row.status,expected);
      if(expected!=='inhabited') assert.equal(row.witness,undefined);
    }
  }
});
