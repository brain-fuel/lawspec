import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createCompiler} from '../api.mjs';
import {compareMigrationSnapshots} from '../migration-correspondence.mjs';

const snapshot={status:'available',version:1,algorithm:'sha256',machineBits:64,
  programDigest:'0'.repeat(64),definitionPlaneDigest:'1'.repeat(64),lawBodiesDigest:'2'.repeat(64),
  definitions:[],contracts:[],dataTypes:[],domainPolicies:[{comparisonId:'domain::law::same',policy:'nonempty'}]};
const domain={comparisonId:'domain::law::same',domainDigest:'a'.repeat(64),status:'inhabited',inputCount:1,
  witness:[{binder:'domain::law::same::bound::0',value:{type:'Bool',value:false}}]};
const facts=row=>({status:'available',version:1,algorithm:'sha256',machineBits:64,lawBodiesEvaluated:false,domains:[row]});
const before={...snapshot,inputDomains:facts(domain)};
const after={...snapshot,programDigest:'3'.repeat(64),domainPolicies:[{comparisonId:'domain::law::same',policy:'universal'}],
  inputDomains:facts({...domain,domainDigest:'b'.repeat(64)})};
const transport={status:'matched',version:1,algorithm:'sha256',machineBits:64,copyValidated:true,originalsUnchanged:true,
  sourceBeforeDigest:before.programDigest,before:{...before,programDigest:'4'.repeat(64),inputDomains:facts(domain)},
  after:{...after,inputDomains:facts(domain)}};
const policy=(value=transport)=>compareMigrationSnapshots(before,after,value).domainPolicies;

test('formal populations require uniform evidence in the same parameter scope',()=>{
  const scoped=(snapshot,policy,row)=>({...snapshot,
    domainPolicies:[{comparisonId:domain.comparisonId,policy,formalParameterCount:1}],inputDomains:facts(row)});
  const witness={...domain,formalParameterCount:1,uniformity:'parameter-independent'};
  const original=scoped(before,'nonempty',witness);
  const compare=row=>compareMigrationSnapshots(original,scoped(after,'universal',row)).domainPolicies;
  assert.equal(compare(witness).status,'matched');
  const missing=structuredClone(witness);delete missing.uniformity;
  const missingScope=structuredClone(witness);delete missingScope.formalParameterCount;
  for(const invalid of [missing,missingScope,{...witness,formalParameterCount:2},
    {...witness,uniformity:'sampled-parameter'}, {...witness,status:'unsupported',complete:false}]) {
    assert.equal(compare(invalid).status,'not-established');
  }
});

const changedBefore={...before,definitionPlaneDigest:'c'.repeat(64),lawBodiesDigest:'d'.repeat(64)};
const bodyCertificate=()=>({...transport,
  program:{status:'not-established',before:transport.before.programDigest,after:transport.after.programDigest},
  definitionPlane:{status:'matched',before:transport.before.definitionPlaneDigest,after:transport.after.definitionPlaneDigest},
  lawBodies:{status:'matched',before:transport.before.lawBodiesDigest,after:transport.after.lawBodiesDigest}});

test('complete validated-copy body and domain certificates establish Core correspondence only',()=>{
  const compared=compareMigrationSnapshots(changedBefore,after,bodyCertificate());
  for(const name of ['program','definitionPlane','lawBodies','domainPolicies']) assert.equal(compared[name].status,'matched');
  assert.equal(compared.program.basis,'matching-complete-Core-after-validated-payload-transport-and-input-domain-correspondence');
  for(const name of ['sourceTemplates','nativeBindings','generatedBehavior']) assert.equal(compared[name].status,'not-established');
  assert.equal(compared.status,'not-established');
  assert.equal(compared.domainPolicies.lawVerification,'not-established-by-domain-evidence');
});

test('input-domain evidence alone cannot clear changed complete-Core bodies',()=>{
  const compared=compareMigrationSnapshots(changedBefore,after,transport);
  assert.equal(compared.domainPolicies.status,'matched');
  for(const name of ['program','definitionPlane','lawBodies']) assert.equal(compared[name].status,'not-established');
});

test('missing, stale or inconsistent validated-copy body pairs cannot establish changed Core',()=>{
  const certificate=bodyCertificate();
  for(const invalid of [undefined,{...certificate,status:'not-established'},
    {...certificate,copyValidated:false},{...certificate,sourceBeforeDigest:'e'.repeat(64)},
    {...certificate,after:{...certificate.after,programDigest:'f'.repeat(64)}},
    {...certificate,before:{...certificate.before,programDigest:'e'.repeat(64)}},
    {...certificate,program:undefined},{...certificate,definitionPlane:undefined},{...certificate,lawBodies:undefined},
    {...certificate,program:{...certificate.program,status:'matched'}},
    {...certificate,definitionPlane:{...certificate.definitionPlane,before:'e'.repeat(64)}},
    {...certificate,lawBodies:{...certificate.lawBodies,after:'e'.repeat(64)}},
    {...certificate,lawBodies:{...certificate.lawBodies,status:'not-established'}},
    {...certificate,after:{...certificate.after,inputDomains:{status:'unavailable'}}}]){
    assert.equal(compareMigrationSnapshots(changedBefore,after,invalid).program.status,'not-established',JSON.stringify(invalid));
  }
});

test('anchored input evidence pairs with already matching complete bodies without validating a migration',()=>{
  assert.equal(policy().status,'matched');
  assert.equal(policy().domains[0].valueRepresentation,'transported-before-and-canonical-after');
  assert.equal(policy().lawVerification,'not-established-by-domain-evidence');
  const report=compareMigrationSnapshots(before,after,transport);
  assert.equal(report.program.status,'matched');
  for(const key of ['status','sourceTemplates','nativeBindings','generatedBehavior']) {
    assert.equal(key==='status'?report.status:report[key].status,'not-established',key);
  }
});

test('missing, stale or malformed transport anchors never clear a changed input policy',()=>{
  for(const value of [{...transport,status:undefined},{...transport,version:2},{...transport,algorithm:'blake3'},
    {...transport,machineBits:32},{...transport,copyValidated:false},{...transport,originalsUnchanged:false},
    {...transport,sourceBeforeDigest:undefined},{...transport,sourceBeforeDigest:'5'.repeat(64)},
    {...transport,before:{...transport.before,domainPolicies:after.domainPolicies}},
    {...transport,after:{...transport.after,domainPolicies:before.domainPolicies}},
    {...transport,after:{...transport.after,programDigest:'6'.repeat(64)}},
    {...transport,before:{...transport.before,machineBits:32}},
    {...transport,after:{...transport.after,definitions:[null]}}]) {
    assert.equal(policy(value).status,'not-established',JSON.stringify(value));
  }
});

test('transport does not hide changed domain predicates or empty, incomplete and malformed searches',()=>{
  for(const row of [{...domain,domainDigest:'c'.repeat(64)},
    {...domain,status:'empty',witness:undefined,complete:true},{...domain,status:'incomplete'},
    {...domain,status:'unsupported'},{...domain,inputCount:2},
    {...domain,witness:[{...domain.witness[0],binder:'different'}]}]) {
    assert.equal(policy({...transport,after:{...transport.after,inputDomains:facts(row)}}).status,'not-established');
  }
});

test('unavailable transported evidence preserves independently matched original domain facts',()=>{
  const second={comparisonId:'domain::law::other',domainDigest:'d'.repeat(64),status:'inhabited',inputCount:0,witness:[]};
  const old={...before,domainPolicies:[...before.domainPolicies,{comparisonId:second.comparisonId,policy:'nonempty'}],
    inputDomains:{...facts(domain),domains:[domain,second]}};
  const next={...after,domainPolicies:[...after.domainPolicies,{comparisonId:second.comparisonId,policy:'universal'}],
    inputDomains:{...after.inputDomains,domains:[...after.inputDomains.domains,second]}};
  const unavailable={...transport,before:{...transport.before,domainPolicies:old.domainPolicies,inputDomains:{status:'unavailable'}},
    after:{...transport.after,domainPolicies:next.domainPolicies}};
  const compared=compareMigrationSnapshots(old,next,unavailable).domainPolicies;
  assert.equal(compared.status,'not-established');
  assert.equal(compared.domains[1].status,'matched');
  assert.equal(compared.domains[1].valueRepresentation,undefined);
});

const compiler=await createCompiler();
const options={schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]}};
const oldType='type Capsule is | Packed last :: Bool first :: Bool end\n';
const newType='type Capsule is one of | Packed of type record{last :: Bool first :: Bool} end type\n';
async function compare(oldExtra='',newExtra='',restriction='',body='value = value') {
  const sources=[{path:'domain.lawspec',content:'unit domain\n'+oldType+oldExtra+
    'law `same` is definition is `for all` (value :: Capsule'+restriction+') . value = value end end'}];
  const migrated={...options,sources:[{path:'domain.lawspec',content:'unit domain\n'+newType+newExtra+
    'law "|same| is definition: for all (value :: Capsule'+restriction+') => '+body+' end end end'}]};
  const result=await compiler.migrationComparison({...options,from:'0.24',sources,migrated});
  assert.deepEqual(result.diagnostics,[]);
  const baseline=await compiler.migrationBaseline({...options,from:'0.24',sources});
  const checked=await compiler.check({...migrated,migrationSnapshot:true});
  const transport=result.migrationComparison.executableTransport;
  assert.equal(transport.copyValidated,true);
  assert.equal(transport.sourceBeforeDigest,baseline.migrationSemantics.programDigest);
  assert.equal(transport.after.programDigest,checked.migrationSemantics.programDigest);
  assert.equal(result.migrationComparison.validated,false);
  return {transport,compared:compareMigrationSnapshots(baseline.migrationSemantics,checked.migrationSemantics,transport)};
}

test('actual checked transport evaluates valid input tuples on both sides without selecting law checks',async()=>{
  const {transport,compared}=await compare();
  for(const snapshot of [transport.before,transport.after]) {
    assert.equal(snapshot.inputDomains.lawBodiesEvaluated,false);
    assert.equal(snapshot.inputDomains.domains[0].status,'inhabited');
  }
  assert.equal(compared.domainPolicies.status,'matched');
  assert.equal(compared.domainPolicies.domains[0].valueRepresentation,'transported-before-and-canonical-after');
  assert.equal(compared.program.status,'matched');
  assert.equal(compared.definitionPlane.status,'matched');
  assert.equal(compared.lawBodies.status,'matched');
  assert.equal(compared.status,'not-established');
});

test('actual changed transitive predicates and complete empty domains remain unestablished',async()=>{
  const changed=await compare('definition allowed (value :: Capsule) :: Bool is value.last end\n',
    'function allowed (value :: Capsule) -> Bool is not value.value.last end function\n',' where allowed value');
  for(const side of ['before','after']) assert.equal(changed.transport[side].inputDomains.domains[0].status,'inhabited');
  assert.equal(changed.compared.domainPolicies.status,'not-established');
  assert.equal(changed.compared.program.status,'not-established');
  const empty=await compare('','',' where false');
  for(const side of ['before','after']) assert.equal(empty.transport[side].inputDomains.domains[0].status,'empty');
  assert.equal(empty.compared.domainPolicies.status,'not-established');
  assert.equal(empty.compared.program.status,'not-established');
});

test('input evidence for a false canonical law cannot establish its body or migration',async()=>{
  const {transport,compared}=await compare('','','','false');
  assert.equal(transport.lawBodies.status,'not-established');
  assert.equal(compared.domainPolicies.status,'matched');
  assert.equal(compared.program.status,'not-established');
  assert.equal(compared.status,'not-established');
});
