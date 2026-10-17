import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createCompiler} from '../api.mjs';
import {compareMigrationSnapshots} from '../migration-correspondence.mjs';

const fields=['declarationsDigest','definitionTemplatesDigest','lawTemplatesDigest','lawBodiesDigest'];
const core={status:'available',version:1,algorithm:'sha256',machineBits:64,
  programDigest:'0'.repeat(64),definitionPlaneDigest:'1'.repeat(64),lawBodiesDigest:'2'.repeat(64),
  definitions:[],contracts:[],dataTypes:[],domainPolicies:[]};
const before={...core,...Object.fromEntries(fields.map((field,index)=>[field,String(index+3).repeat(64)])),units:[],laws:[]};
const after={...before,definitionTemplatesDigest:'8'.repeat(64),declarationsDigest:'9'.repeat(64)};
const anchors=snapshot=>Object.fromEntries(fields.map(field=>[field,snapshot[field]]));
const transport={status:'matched',version:1,algorithm:'sha256',machineBits:64,copyValidated:true,originalsUnchanged:true,
  sourceBeforeDigest:'a'.repeat(64),before:core,after:core,
  ...Object.fromEntries([['program','programDigest'],['definitionPlane','definitionPlaneDigest'],['lawBodies','lawBodiesDigest']]
    .map(([name,field])=>[name,{status:'matched',before:core[field],after:core[field]}]))};
const certificate={status:'matched',version:1,algorithm:'sha256',machineBits:64,originalsUnchanged:true,
  before:anchors(before),after:anchors(after),
  interfaces:{status:'matched',before:'b'.repeat(64),after:'b'.repeat(64)},typedCore:transport};
const compare=evidence=>compareMigrationSnapshots({...core,sourceTemplates:before},
  {...core,sourceTemplates:after},undefined,evidence);

test('symbolic definition evidence clears only its anchored template component',()=>{
  const result=compare(certificate);
  assert.equal(result.sourceTemplates.definitions.status,'matched');
  assert.match(result.sourceTemplates.definitions.basis,/symbolic-definition-Core/);
  for(const component of ['declarations','status']) assert.equal(result.sourceTemplates[component]?.status??result.sourceTemplates[component],'not-established');
  assert.equal(result.nativeBindings.status,'not-established');
  assert.equal(result.generatedBehavior.status,'not-established');
  assert.equal(result.status,'not-established');
});

test('stale, incomplete, cross-width and malformed symbolic certificates cannot clear a template change',()=>{
  const invalid=[undefined,null,{...certificate,status:'not-established'},{...certificate,version:2},
    {...certificate,machineBits:32},{...certificate,algorithm:'unknown'},{...certificate,originalsUnchanged:false},
    ...fields.flatMap(field=>[{...certificate,before:{...certificate.before,[field]:'c'.repeat(64)}},
      {...certificate,after:{...certificate.after,[field]:'c'.repeat(64)}}]),
    {...certificate,interfaces:{...certificate.interfaces,status:'not-established'}},
    {...certificate,interfaces:{...certificate.interfaces,after:'c'.repeat(64)}},
    {...certificate,interfaces:{status:'matched'}},
    ...[undefined,{...transport,status:'not-established'},{...transport,copyValidated:false},
      {...transport,originalsUnchanged:false},{...transport,machineBits:32},{...transport,sourceBeforeDigest:undefined},
      {...transport,before:{...core,machineBits:32}},{...transport,after:{...core,status:'unavailable'}},
      {...transport,definitionPlane:{...transport.definitionPlane,after:'c'.repeat(64)}},
      {...transport,lawBodies:{...transport.lawBodies,status:'not-established'}},
      {...transport,before:{...core,domainPolicies:[{comparisonId:'law',policy:'universal'}]}}]
      .map(typedCore=>({...certificate,typedCore}))];
  for(const evidence of invalid) assert.equal(compare(evidence).sourceTemplates.definitions.status,'not-established');
});

const compiler=await createCompiler();
const options={schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]}};
const sources=body=>[{path:'symbolic.lawspec',content:'unit symbolic\n'+body}];
const oldType='type Capsule (a :: Type) is | Packed last :: Bool first :: a end\n';
const newType='type Capsule (a :: Type) is one of | Packed of type record{last :: Bool first :: a} end type\n';
const oldRead='definition read (input :: Capsule a) :: a is match input with | Packed last first -> first end end';
const newRead='function read (input :: Capsule a) -> a is first matching case of input: when Packed record{last = last, first = first} then first end case end function';
const oldProjection='definition read (input :: Capsule a) :: a is input.first end';
const newProjection='function read (input :: Capsule a) -> a is input.value.first end function';
async function compareSources(before,after,machineBits=64) {
  const result=await compiler.migrationComparison({...options,from:'0.24',machineBits,sources:sources(before),
    migrated:{...options,machineBits,sources:sources(after)}});
  assert.deepEqual(result.diagnostics,[]);
  assert.equal(result.verification.selection,'no-selected-checks');
  assert.equal(result.migrationComparison.validated,false);
  return result.migrationComparison.definitionTemplates;
}

test('complete unused generic definitions match symbolically at both machine widths',async()=>{
  for(const machineBits of [32,64])for(const [readBefore,readAfter] of [[oldRead,newRead],[oldProjection,newProjection]]) {
    const evidence=await compareSources(oldType+readBefore,newType+readAfter,machineBits);
    assert.equal(evidence.status,'matched',JSON.stringify(evidence));
    assert.equal(evidence.typedCore.copyValidated,true);
    assert.equal(evidence.interfaces.status,'matched');
    assert.equal(evidence.typeVariables,'symbolic; no sample instantiations');
    const original=await compiler.migrationBaseline({...options,from:'0.24',machineBits,sources:sources(oldType+readBefore)});
    const migrated=await compiler.check({...options,migrationSnapshot:true,machineBits,sources:sources(newType+readAfter)});
    assert.deepEqual(original.diagnostics,[]);
    assert.deepEqual(migrated.diagnostics,[]);
    const result=compareMigrationSnapshots(original.migrationSemantics,migrated.migrationSemantics,undefined,evidence);
    assert.equal(result.sourceTemplates.definitions.status,'matched');
    assert.equal(result.sourceTemplates.status,'not-established');
    assert.deepEqual(evidence.before,anchors(original.migrationSemantics.sourceTemplates));
    assert.deepEqual(evidence.after,anchors(migrated.migrationSemantics.sourceTemplates));
  }
});

test('a pure product projection matches its exhaustive single-branch pattern',async()=>{
  const evidence=await compareSources(oldType+oldRead,newType+newProjection);
  assert.equal(evidence.status,'matched');
  assert.equal(evidence.interfaces.status,'matched');
  assert.equal(evidence.typedCore.copyValidated,true);
  assert.equal(evidence.typedCore.definitionPlane.status,'matched');
});

test('unused generic dependency and capability mutants remain unestablished',async()=>{
  for(const [before,after,part] of [
    ['definition helper (left :: a) (right :: a) :: a is left end\ndefinition choose (left :: a) (right :: a) :: a is helper left right end',
      'function helper (left :: a) (right :: a) -> a is right end function\nfunction choose (left :: a) (right :: a) -> a is helper left right end function','typedCore'],
    ['definition same (value :: a) :: a requires Eq a is value end',
      'function same (value :: a) -> a requires Keyed a is value end function','interfaces'],
  ]) {
    const evidence=await compareSources(before,after);
    assert.equal(evidence.status,'not-established');
    assert.equal(evidence[part].status,'not-established');
  }
});

test('declared generic equality is supported while ordinary source admission remains mandatory',async()=>{
  const evidence=await compareSources('definition equal (left :: a) (right :: a) :: Bool requires Eq a is left == right end',
    'function equal (left :: a) (right :: a) -> Bool requires Eq a is left = right end function');
  assert.equal(evidence.status,'matched');
  assert.equal(evidence.typedCore.copyValidated,true);
  const rejected=await compiler.migrationComparison({...options,from:'0.24',sources:sources('definition invalid (unused :: a) :: Integer is 1 / 0 end'),
    migrated:{...options,sources:sources('function invalid (unused :: a) -> Integer is 1 / 0 end function')}});
  assert.notDeepEqual(rejected.diagnostics,[]);
  assert.equal(rejected.migrationComparison,undefined);
});
