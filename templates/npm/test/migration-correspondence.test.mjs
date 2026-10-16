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
    assert.equal(report.correspondence.status,'not-established');
    assert.equal(report.validated,false);
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

test('actual snapshot equality keeps law bodies separate from changed empty-domain policy',async()=>{
  const sources=[{path:'law.lawspec',content:'unit domain\nlaw `same` is definition is `for all` (value :: Bool) . value = value end end'}];
  const report=await migrationReport(compiler,{version:1,targets:[]},{sources});
  assert.equal(report.sourcePreview.canonicalCheck.status,'accepted');
  assert.equal(report.correspondence.definitionPlane.status,'matched');
  assert.equal(report.correspondence.lawBodies.status,'matched');
  assert.equal(report.correspondence.domainPolicies.status,'not-established');
  assert.equal(report.correspondence.program.status,'not-established');
  assert.deepEqual(report.correspondence.domainPolicies.before,[{comparisonId:'domain::law::same',policy:'nonempty'}]);
  assert.deepEqual(report.correspondence.domainPolicies.after,[{comparisonId:'domain::law::same',policy:'universal'}]);
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

test('Chapter 6 reports actual payload-shape differences instead of silently erasing nominal boundaries',async()=>{
  const content=await readFile(new URL('../../test/fixtures/migration-chap06-0.24.lawspec',import.meta.url),'utf8');
  const report=await migrationReport(compiler,{version:1,targets:[]},{sources:[{path:'chap06.lawspec',content}]});
  assert.equal(report.sourcePreview.canonicalCheck.status,'accepted');
  assert.equal(report.correspondence.program.status,'not-established');
  assert.equal(report.correspondence.nativeBindings.status,'not-established');
  assert.deepEqual(report.correspondence.differences.dataTypes.changed,['nand2tetris.chap06::type::Predefined','nand2tetris.chap06::type::Line']);
  assert.equal(report.correspondence.differences.dataTypes.added.length,1);
  assert.ok(report.correspondence.differences.dataTypes.added[0].startsWith('lawspec::structural::record::'));
  assert.equal(report.correspondence.differences.definitions.changed.length,8);
  assert.equal(report.correspondence.domainPolicies.before.length,23);
  assert.equal(report.correspondence.domainPolicies.status,'not-established');
  assert.equal(report.validated,false);
  assert.deepEqual(report.filesWritten,[]);
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
