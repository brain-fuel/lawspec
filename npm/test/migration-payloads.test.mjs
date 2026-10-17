// Generated from templates/npm/test/migration-payloads.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createCompiler} from '../api.mjs';
import {migrationReport} from '../migrate.mjs';

const compiler=await createCompiler();
const options={schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]}};
const sources=body=>[{path:'payloads.lawspec',content:'unit payloads\n'+body}];
const old='type Variant is | Empty | Item last :: Bool first :: UInt8 end';
const canonical='type Variant is one of | Empty | Item of type record{last :: Bool first :: UInt8} end type';
const compare=(before,after,bits=64)=>compiler.migrationComparison({...options,from:'0.24',sources:sources(before),machineBits:bits,
  migrated:{...options,sources:sources(after),machineBits:bits}});

test('single indexed and existential payload formals retain their exact checked metadata',async()=>{
  for(const machineBits of [32,64])for(const [before,after] of [
    ['type Expr (a :: Type) is | Truth flag :: Bool where a = Bool end',
      'type Expr (a :: Type) is one of | Truth of type Bool where a = Bool end type'],
    ['type Chain (n :: Natural) is | Stop where n = 0 | Next link :: Chain m where n = m + 1 end',
      'type Chain (n :: Whole) is one of | Stop where n = 0 | Next of type Chain m where n = m + 1 end type'],
    ['type Box (a :: Type) is Box held :: Bool where a = Bool end',
      'type Box (a :: Type) is one of Box of type Bool where a = Bool end type'],
    ['type Shown is Shown held :: a end','type Shown is one of Shown of type a end type']
  ]){
    const result=await compare(before,after,machineBits);
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.migrationComparison.payloadShapes.status,'matched');
    assert.equal(result.migrationComparison.executableTransport.status,'matched');
    assert.equal(result.migrationComparison.executableTransport.copyValidated,true);
    assert.equal(result.migrationComparison.validated,false);
  }
  const changed=await compare('type Expr (a :: Type) is Truth flag :: Bool where a = Bool end',
    'type Expr (a :: Type) is one of Truth of type Bool where a = UInt8 end type');
  assert.deepEqual(changed.diagnostics,[]);
  assert.equal(changed.migrationComparison.payloadShapes.status,'not-established');
});

test('checked constructor classification keeps a same-named existential constructor out of nominal record migration',async()=>{
  for(const machineBits of [32,64])for(const [before,nominal] of [
    ['type Shown is Shown held :: a end',false],
    ['type Box (a :: Type) is Box held :: Bool where a = Bool end',false],
    ['type Box (a :: Type) is Box held :: a end',true]
  ]){
    const report=await migrationReport(compiler,{version:1,targets:[]},{sources:sources(before),machineBits});
    assert.deepEqual(report.diagnostics,[]);
    assert.equal(report.sourcePreview.canonicalCheck.status,'accepted');
    const facts=report.baseline.sourceFields;
    assert.equal(facts.status,'available');
    const name=before.includes('Shown')?'Shown':'Box';
    assert.equal(facts.constructors.find(value=>value.constructor==='payloads::type::'+name+'::'+name)?.nominalRecord,nominal);
    const content=report.sourcePreview.sources[0].content;
    assert.ok(content.includes(nominal?'is a record{':'is one of'),content);
  }
});

test('missing checked constructor classification blocks a same-named record preview rather than guessing',async()=>{
  const incomplete={...compiler,migrationBaseline:async input=>{
    const result=structuredClone(await compiler.migrationBaseline(input));
    assert.equal(result.sourceFields.status,'available');
    delete result.sourceFields.constructors;
    return result;
  }};
  const report=await migrationReport(incomplete,{version:1,targets:[]},
    {sources:sources('type Box is Box held :: Bool end')});
  assert.equal(report.validated,false);
  assert.ok(report.sourcePreview.diagnostics.some(value=>/checked constructor classification/.test(value.message)));
  assert.deepEqual(report.filesWritten,[]);
});

test('compiler-side payload comparison certifies both widths with an explicit field permutation',async()=>{
  for(const bits of [32,64]) {
    const result=await compare(old,canonical,bits);
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.verification.selection,'no-selected-checks');
    const value=result.migrationComparison;
    assert.equal(value.status,'not-established');
    assert.equal(value.payloadShapes.status,'matched');
    assert.equal(value.validated,false);
    assert.equal(value.algorithm,'sha256');
    assert.equal(value.dependencyBehavior.status,'not-established');
    assert.equal(value.executableTransport.status,'matched');
    assert.equal(value.executableTransport.copyValidated,true);
    assert.equal(value.executableTransport.definitionPlane.status,'matched');
    assert.equal(value.nativeBindings.status,'not-established');
    assert.equal(value.lawVerification,'not-established-by-payload-shapes');
    const fields=value.payloadShapes.changes.flatMap(type=>type.constructors??[]).flatMap(ctor=>ctor.fields??[]);
    assert.deepEqual(fields.map(field=>[field.label,field.fromIndex,field.toIndex]),[['last',0,1],['first',1,0]]);
    assert.equal(value.payloadShapes.introducedRecords.length,1);
  }
});

test('unused generic payload relationships and dependent refinements survive shape comparison',async()=>{
  const before='type Variant (a :: Type) is | Empty | Item first :: a second :: a end';
  const after='type Variant (a :: Type) is one of | Empty | Item of type record{first :: a second :: a} end type';
  const generic=await compare(before,after);
  assert.deepEqual(generic.diagnostics,[]);
  assert.equal(generic.migrationComparison.payloadShapes.status,'matched');
  const restrictedBefore='type Variant is | Empty | Item first :: UInt8 second :: (n :: UInt8 where n >= first) end';
  const restrictedAfter='type Variant is one of | Empty | Item of type record{first :: UInt8 second :: (n :: UInt8 where n >= first)} end type';
  const restricted=await compare(restrictedBefore,restrictedAfter);
  assert.deepEqual(restricted.diagnostics,[]);
  assert.equal(restricted.migrationComparison.payloadShapes.status,'matched');
  const mutant=await compare(restrictedBefore,restrictedAfter.replace('>=','>'));
  assert.deepEqual(mutant.diagnostics,[]);
  assert.equal(mutant.migrationComparison.payloadShapes.status,'not-established');
});

test('payload descriptors reject labels, types, extra fields and nominal substitution',async()=>{
  for(const after of [canonical.replace('last ::','renamed ::'),canonical.replace('first :: UInt8','first :: UInt16'),
    canonical.replace('first :: UInt8','first :: UInt8 extra :: Bool'),
    'type Payload is a record{last :: Bool first :: UInt8} end type\ntype Variant is one of | Empty | Item of type Payload end type']) {
    const result=await compare(old,after);
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.migrationComparison.payloadShapes.status,'not-established');
  }
});

test('both comparison inputs retain mandatory validation and explicit schema/profile boundaries',async()=>{
  const input={...options,from:'0.24',sources:sources(old),migrated:{...options,sources:sources(canonical)}};
  for(const changed of [{...input,schemaVersion:4},{...input,from:'0.23'},
    {...input,verification:{layers:['examples']}},
    {...input,migrated:{...input.migrated,schemaVersion:4}},
    {...input,migrated:{sources:sources(canonical)}},
    {...input,migrated:{...input.migrated,machineBits:32}},
    {...input,migrated:{...input.migrated,verification:{layers:['proof']}}},
    {...input,sources:sources(old+'\ndefinition unsafe (n :: Integer) :: Integer is 1 / n end')},
    {...input,migrated:{...input.migrated,sources:sources(canonical+'\nfunction unsafe (n :: Integer) -> Integer is 1 / n end function')}},
    {...input,migrated:{...input.migrated,nativeBindings:{types:[{type:'missing::Type',native:['Missing']}]}}}]) {
    const result=await compiler.migrationComparison(changed);
    assert.ok(result.diagnostics.length>0,JSON.stringify(changed));
    assert.equal(result.migrationComparison,undefined);
  }
  const ordinary=await compiler.check({...options,sources:sources(canonical)});
  assert.deepEqual(ordinary.diagnostics,[]);
  assert.equal(ordinary.migrationComparison,undefined);
});

test('the read-only report validates checked payload migration without selecting target execution',async()=>{
  const report=await migrationReport(compiler,{version:1,targets:[]},{sources:sources(old)});
  assert.deepEqual(report.diagnostics,[]);
  assert.equal(report.sourcePreview.canonicalCheck.status,'accepted');
  assert.equal(report.correspondence.payloads.payloadShapes.status,'matched');
  assert.equal(report.correspondence.program.status,'matched');
  assert.equal(report.correspondence.nativeBindings.status,'matched');
  assert.equal(report.correspondence.nativeBindings.configurationCount,0);
  assert.equal(report.correspondence.generatedBehavior.status,'not-requested');
  assert.equal(report.correspondence.status,'matched-under-existing-assumptions');
  assert.equal(report.validated,true,JSON.stringify(report.blockers));
  assert.deepEqual(report.filesWritten,[]);
});
