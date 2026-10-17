// Generated from templates/npm/test/migration-profiles.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createCompiler} from '../api.mjs';
import {migrationReport,legacyLawLayers} from '../migrate.mjs';

const compiler=await createCompiler();
const options={schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]}};
const policies=snapshot=>snapshot.sourceTemplates.domainPolicies;

test('migration coordination needs only explicit legacy entry points and canonical ordinary requests',async()=>{
  const requests=[];
  const strict={...compiler,
    check:input=>{
      assert.equal(input.schemaVersion,5);assert.equal(input.languageProfile,'1.0-rc.1');
      return compiler.check(input);
    },
    migrationBaseline:input=>{
      assert.equal(input.schemaVersion,5);assert.equal(input.from,'0.24');
      requests.push(input);return compiler.migrationBaseline(input);
    },
  };
  const sources=[{path:'explicit.lawspec',content:'unit explicit\n'+
    'definition same (value :: Bool) :: Bool is value end\n'+
    'law `identity` is definition is `for all` (value :: Bool) . same value = value end end'}];
  const report=await migrationReport(strict,{version:1,targets:[]},{sources});
  assert.equal(report.validated,true,JSON.stringify(report.blockers));
  assert.deepEqual(requests.map(request=>request.verification.layers),[legacyLawLayers]);
  const independent=await compiler.migrationBaseline({...options,from:'0.24',sources});
  assert.deepEqual(report.baseline.coreSnapshot,independent.migrationSemantics);
  assert.equal(report.validation.lawVerification,'not-established-by-migration');
  for(const content of [
    'definition unsafe (value :: Integer) :: Integer is 1 / value end',
    'type Flag is | Off | On end\ndefinition unsafe (value :: Flag) :: Bool is match value with | Off -> true end end',
    'law `false` is definition is true = false end end',
  ]){
    const rejected=await migrationReport(strict,{version:1,targets:[]},{sources:[{path:'invalid.lawspec',content:'unit invalid\n'+content}]});
    assert.equal(rejected.validated,false);assert.ok(rejected.diagnostics.length);
    assert.ok(rejected.diagnostics.every(diagnostic=>!['request','parse'].includes(diagnostic.code)));
  }
});

test('migration keeps versioned dependency templates while comparing monomorphic authored sources',async()=>{
  for(const machineBits of [32,64])for(const law of [false,true]){
    const sources=[{path:'migration.lawspec',content:'unit migration\n'+
      'definition same (value :: Bool) :: Bool is value end\n'+
      (law?'law `kept` is definition is `for all` (value :: Bool) . same value = value end end':'')}];
    const report=await migrationReport(compiler,{version:1,targets:[]},{sources,machineBits});
    assert.deepEqual(report.diagnostics,[]);
    assert.equal(report.sourcePreview.canonicalCheck.status,'accepted');
    assert.equal(report.correspondence.sourceTemplates.status,'matched',JSON.stringify(report.correspondence.sourceTemplates));
    assert.equal(report.correspondence.program.status,'matched');
    assert.ok(!report.blockers.some(reason=>reason.includes('empty-domain')||reason.includes('source-template')));
    assert.equal(report.correspondence.nativeBindings.status,'matched');
    assert.equal(report.correspondence.nativeBindings.configurationCount,0);
    assert.equal(report.correspondence.generatedBehavior.status,'not-requested');
    assert.deepEqual(report.blockers,[]);
    const before=report.baseline.coreSnapshot,after=report.sourcePreview.canonicalCheck.coreSnapshot;
    const dependency=row=>row.comparisonId.startsWith('prelude::law::');
    assert.ok(policies(before).some(dependency));
    assert.deepEqual(policies(before).filter(dependency),policies(after).filter(dependency));
    assert.ok(policies(after).filter(dependency).every(row=>row.policy==='nonempty'));
    if(law){
      assert.equal(policies(before).find(row=>row.comparisonId==='migration::law::kept').policy,'nonempty');
      assert.equal(policies(after).find(row=>row.comparisonId==='migration::law::kept').policy,'universal');
    }
    assert.equal(report.validated,true);
    assert.equal(report.validation.lawVerification,'not-established-by-migration');
    assert.deepEqual(report.filesWritten,[]);
  }
});

test('an authored generic population-policy change remains unestablished',async()=>{
  for(const machineBits of [32,64]){
    const sources=[{path:'generic.lawspec',content:'unit generic\n'+
      'law `kept` (operation :: a -> a) requires Eq a is '+
      'definition is `for all` (value :: a) . operation value = value end end'}];
    const report=await migrationReport(compiler,{version:1,targets:[]},{sources,machineBits});
    assert.equal(report.sourcePreview.canonicalCheck.status,'accepted');
    assert.equal(report.correspondence.sourceTemplates.lawBodies.status,'matched');
    assert.equal(report.correspondence.sourceTemplates.domainPolicies.status,'not-established');
    assert.equal(report.correspondence.sourceTemplates.status,'not-established');
    assert.ok(report.blockers.some(reason=>reason.includes('empty-domain')));
    assert.ok(report.correspondence.sourceTemplates.domainPolicies.domains.some(row=>
      row.comparisonId==='generic::law::kept'&&row.status==='not-established'));
    assert.equal(report.validated,false);
  }
});

test('canonical callers of the versioned prelude retain universal empty-domain semantics',async()=>{
  for(const machineBits of [32,64])for(const [declaration,type] of [
    ['','Bool'],['type Empty is one of end type\n','Empty']]){
    const result=await compiler.check({...options,machineBits,migrationSnapshot:true,sources:[{
      path:'caller.lawspec',content:'unit caller\n'+declaration+
        `operation :: ${type} -> ${type}\nlaw kept is definition: apply law prelude."|idempotent| operation end end`,
    }]});
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.laws.find(law=>law.owner==='caller').inputDomain,'universal');
    assert.equal(result.evidence.find(row=>row.stage==='law'&&row.owner==='caller').status,'not-verified');
    assert.ok(policies(result.migrationSemantics).filter(row=>row.comparisonId.startsWith('prelude::law::'))
      .every(row=>row.policy==='nonempty'));
  }
});
