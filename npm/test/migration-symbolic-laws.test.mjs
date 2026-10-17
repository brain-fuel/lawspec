// Generated from templates/npm/test/migration-symbolic-laws.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createCompiler} from '../api.mjs';
import {compareMigrationSnapshots} from '../migration-correspondence.mjs';

const digest=value=>value.repeat(64);
const fields=['declarationsDigest','definitionTemplatesDigest','lawTemplatesDigest','lawBodiesDigest'];
const core={status:'available',version:1,algorithm:'sha256',machineBits:64,programDigest:digest('0'),
  definitionPlaneDigest:digest('1'),lawBodiesDigest:digest('2'),definitions:[],contracts:[],dataTypes:[],domainPolicies:[]};
const templates={status:'available',version:1,algorithm:'sha256',machineBits:64,
  ...Object.fromEntries(fields.map((field,index)=>[field,digest(String(index+3))])),
  units:[],definitions:[],laws:[],domainPolicies:[{comparisonId:'unit::law::unused',policy:'nonempty'}]};
const after={...templates,...Object.fromEntries(fields.map((field,index)=>[field,digest(String(index+6))]))};
const anchors=value=>Object.fromEntries(fields.map(field=>[field,value[field]]));
const pair=value=>({status:'matched',before:value,after:value});
const typedCore={status:'matched',version:1,algorithm:'sha256',machineBits:64,copyValidated:true,originalsUnchanged:true,
  sourceBeforeDigest:digest('a'),before:core,after:core,program:pair(core.programDigest),
  definitionPlane:pair(core.definitionPlaneDigest),lawBodies:pair(core.lawBodiesDigest)};
const base={status:'matched',version:1,algorithm:'sha256',machineBits:64,originalsUnchanged:true,
  before:anchors(templates),after:anchors(after)};
const definitions={...base,interfaces:pair(digest('b')),typedCore};
const laws={...base,lawBodiesEvaluated:false,metadata:pair(digest('c')),
  typedCore:{...typedCore,before:{...core,domainPolicies:templates.domainPolicies},after:{...core,domainPolicies:after.domainPolicies}}};
const units={...base,metadata:pair(digest('d')),definitions:'matched',laws:'matched',payloadShapes:'matched'};
const compare=(definition=definitions,law=laws,unit=units)=>compareMigrationSnapshots(
  {...core,sourceTemplates:templates},{...core,sourceTemplates:after},undefined,definition,law,unit);

test('source terms and full remaining metadata compose while keeping migration and law truth unestablished',()=>{
  const result=compare();
  assert.equal(result.sourceTemplates.status,'matched');
  assert.match(result.sourceTemplates.declarations.basis,/source-unit-metadata/);
  assert.match(result.sourceTemplates.lawBodies.basis,/symbolic-law-Core/);
  assert.equal(result.nativeBindings.status,'not-established');
  assert.equal(result.generatedBehavior.status,'not-established');
  assert.equal(result.status,'not-established');
});

test('partial, stale and malformed symbolic law/unit facts cannot discharge source correspondence',()=>{
  for(const law of [null,{...laws,status:'not-established'},{...laws,lawBodiesEvaluated:true},
    {...laws,version:2},{...laws,machineBits:32},{...laws,metadata:{status:'matched'}},
    {...laws,typedCore:{...laws.typedCore,before:core}},
    {...laws,typedCore:{...laws.typedCore,lawBodies:{...typedCore.lawBodies,after:digest('e')}}},
    ...fields.map(field=>({...laws,after:{...laws.after,[field]:digest('e')}}))]) {
    assert.equal(compare(definitions,law).sourceTemplates.status,'not-established');
  }
  for(const unit of [null,{...units,status:'not-established'},{...units,originalsUnchanged:false},
    {...units,definitions:'not-established'},{...units,laws:'not-established'},{...units,payloadShapes:'not-established'},
    {...units,metadata:{...units.metadata,after:digest('e')}},
    ...fields.map(field=>({...units,before:{...units.before,[field]:digest('e')}}))]) {
    assert.equal(compare(definitions,laws,unit).sourceTemplates.declarations.status,'not-established');
  }
  assert.equal(compare(null).sourceTemplates.status,'not-established');
});

const compiler=await createCompiler();
const options={schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]}};
const sources=body=>[{path:'symbolic.lawspec',content:'unit symbolic\n'+body}];
async function compareSources(before,after,machineBits=64) {
  const result=await compiler.migrationComparison({...options,from:'0.24',machineBits,sources:sources(before),
    migrated:{...options,machineBits,sources:sources(after)}});
  assert.deepEqual(result.diagnostics,[]);
  assert.equal(result.verification.selection,'no-selected-checks');
  assert.equal(result.migrationComparison.validated,false);
  return result.migrationComparison;
}

test('unused generic laws keep symbolic parameters, their Eq scope and separate population policies',async()=>{
  for(const machineBits of [32,64])for(const name of ['same','same%:policy']) {
    const before='law `'+name+'` (operation :: a -> a) requires Eq a is definition is `for all` (value :: a) . operation value = value end end';
    const after='law "|'+name+'| (operation :: a -> a) requires Eq a is definition: for all (value :: a) => operation value must be value end end end';
    const result=await compareSources(before,after,machineBits);
    assert.equal(result.lawTemplates.status,'matched',JSON.stringify(result.lawTemplates));
    assert.equal(result.lawTemplates.lawBodiesEvaluated,false);
    assert.equal(result.lawTemplates.typedCore.copyValidated,true);
    assert.equal(result.lawTemplates.typedCore.program.status,'not-established');
    assert.match(result.lawTemplates.parameterInterpretation,/no parameter implementation/);
    assert.equal(result.sourceUnits.status,'matched');
    const old=await compiler.migrationBaseline({...options,from:'0.24',machineBits,sources:sources(before)});
    const made=await compiler.check({...options,machineBits,migrationSnapshot:true,sources:sources(after)});
    const compared=compareMigrationSnapshots(old.migrationSemantics,made.migrationSemantics,result.executableTransport,
      result.definitionTemplates,result.lawTemplates,result.sourceUnits);
    assert.equal(compared.sourceTemplates.declarations.status,'matched');
    assert.equal(compared.sourceTemplates.lawBodies.status,'matched');
    assert.equal(compared.sourceTemplates.domainPolicies.status,'not-established');
    assert.equal(compared.sourceTemplates.status,'not-established');
  }
});

test('generic value parameters and list membership retain Eq without Keyed or a concrete witness',async()=>{
  const result=await compareSources(
    'law `member` (needle :: a) requires Eq a is definition is `for all` (items :: List a) . (items contains needle) = (items contains needle) end end',
    'law "|member| (needle :: a) requires Eq a is definition: for all (items :: List a) => (items contains needle) must be (items contains needle) end end end');
  assert.equal(result.lawTemplates.status,'matched',JSON.stringify(result.lawTemplates));
  assert.equal(result.lawTemplates.lawVerification,'not-established-by-migration-correspondence');
});

test('unused reusable bodies, requirements and documentary metadata remain independent checks',async()=>{
  const before='law `same` (operation :: a -> a) requires Eq a is definition is `for all` (value :: a) . operation value = value end end';
  for(const after of [
    'law "|same| (operation :: a -> a) requires Eq a is definition: for all (value :: a) => value must be value end end end',
    'law "|same| (operation :: a -> a) requires Keyed a is definition: for all (value :: a) => operation value must be value end end end',
    'law "|same| (operation :: a -> a) requires Eq a is description: "Changed requirement" end definition: for all (value :: a) => operation value must be value end end end',
  ]) {
    const result=await compareSources(before,after);
    assert.equal(result.lawTemplates.status,'not-established');
    assert.equal(result.sourceUnits.status,'not-established');
  }
});
