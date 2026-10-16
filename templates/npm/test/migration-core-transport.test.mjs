import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createCompiler} from '../api.mjs';

const compiler=await createCompiler();
const options={schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]}};
const sources=body=>[{path:'transport.lawspec',content:'unit transport\n'+body}];
const oldType='type Capsule is | Packed last :: Bool first :: Bool end\n';
const newType='type Capsule is one of | Packed of type record{last :: Bool first :: Bool} end type\n';
const oldMake='definition make (flag :: Bool) :: Capsule is Packed flag false end\n';
const newMake='function make (flag :: Bool) -> Capsule is Packed record{last = flag, first = false} end function\n';
async function compare(before,after,machineBits=64) {
  const result=await compiler.migrationComparison({...options,from:'0.24',machineBits,sources:sources(before),
    migrated:{...options,machineBits,sources:sources(after)}});
  assert.deepEqual(result.diagnostics,[]);
  assert.equal(result.verification.selection,'no-selected-checks');
  assert.equal(result.migrationComparison.payloadShapes.status,'matched');
  assert.equal(result.migrationComparison.status,'not-established');
  assert.equal(result.migrationComparison.validated,false);
  assert.equal(result.migrationComparison.nativeBindings.status,'not-established');
  return result.migrationComparison.executableTransport;
}

test('checked concrete transport matches constructions, patterns, projections and updates at both widths',async()=>{
  const cases=[
    [oldMake,newMake],
    ['definition read (input :: Capsule) :: Bool is match input with | Packed last first -> last end end',
     'function read (input :: Capsule) -> Bool is first matching case of input: when Packed record{last = last, first = first} then last end case end function'],
    ['definition read (input :: Capsule) :: Bool is input.last end',
     'function read (input :: Capsule) -> Bool is input.value.last end function'],
    ['definition change (input :: Capsule) (replacement :: Bool) :: Capsule is input with last = replacement end',
     'function change (input :: Capsule) (replacement :: Bool) -> Capsule is Packed (input.value with last = replacement) end function'],
  ];
  for(const bits of [32,64])for(const [before,after] of cases) {
    const result=await compare(oldType+before,newType+after,bits);
    assert.equal(result.status,'matched',JSON.stringify(result));
    assert.equal(result.copyValidated,true);
    assert.equal(result.originalsUnchanged,true);
    assert.equal(result.definitionPlane.status,'matched');
    assert.equal(result.program.status,'matched');
    assert.ok(result.assumptions.some(text=>text.includes('native conformance')));
  }
});

test('transport comparisons use the actual canonical snapshot and keep body mutants unestablished',async()=>{
  const result=await compare(oldType+oldMake,newType+newMake);
  const checked=await compiler.check({...options,migrationSnapshot:true,sources:sources(newType+newMake)});
  assert.deepEqual(checked.diagnostics,[]);
  assert.equal(result.after.programDigest,checked.migrationSemantics.programDigest);
  assert.equal(result.after.definitionPlaneDigest,checked.migrationSemantics.definitionPlaneDigest);
  const mutant=await compare(oldType+oldMake,newType+newMake.replace('last = flag','last = not flag'));
  assert.equal(mutant.copyValidated,true);
  assert.equal(mutant.status,'not-established');
  assert.equal(mutant.definitionPlane.status,'not-established');
});

test('transported law bodies cannot erase a changed population policy',async()=>{
  const before=oldType+oldMake+'law `same` is definition is `for all` (flag :: Bool) . make flag = Packed flag false end end';
  const after=newType+newMake+'law "|same| is definition: for all (flag :: Bool) => make flag must be Packed record{last = flag, first = false} end end end';
  const result=await compare(before,after);
  assert.equal(result.status,'matched');
  assert.equal(result.lawBodies.status,'matched');
  assert.equal(result.program.status,'not-established');
  assert.equal(result.domainPolicies.status,'not-established');
});

test('generic payload transport resolves the local Pair alternative before the implicit prelude record',async()=>{
  const before='type Box (a :: Type) is | Empty | Pair last :: a first :: a end\ndefinition make (flag :: Bool) :: Box Bool is Pair flag false end';
  const after='type Box (a :: Type) is one of | Empty | Pair of type record{last :: a first :: a} end type\nfunction make (flag :: Bool) -> Box Bool is Pair record{last = flag, first = false} end function';
  const result=await compare(before,after);
  assert.equal(result.status,'matched',JSON.stringify(result));
  assert.equal(result.copyValidated,true);
});

test('affected ordering, recording and concurrency report explicit limits instead of matching raw nodes',async()=>{
  const ability='ability Trace is mark :: Bool -> Bool end\n';
  const cases=[
    ['definition order (left :: Capsule) (right :: Capsule) :: Ordering is prelude.compare left right end',
     'function order (left :: Capsule) (right :: Capsule) -> Ordering is prelude.compare left right end function','legacy-order comparator'],
    ['law `snapshot` is definition is Packed true false = recorded "shape" end end',
     'law "|snapshot| is definition: Packed record{last = true, first = false} must be recorded "shape" end end','recorded values'],
    [ability+'definition run (flag :: Bool) :: Capsule is prelude.concurrently (Packed (mark flag) (mark true)) end',
     ability+'procedure run (flag :: Bool) -> Capsule is prelude.concurrently (Packed record{last = mark flag, first = mark true}) end procedure','scheduling-preserving'],
  ];
  for(const [before,after,reason] of cases) {
    const result=await compare(oldType+before,newType+after);
    assert.equal(result.status,'not-established');
    assert.equal(result.copyValidated,undefined);
    assert.ok(result.reason.includes(reason),result.reason);
  }
});

test('recorded scalar laws retain their typed meaning across all canonical equality spellings',async()=>{
  const before='definition value (flag :: Bool) :: Bool is flag end\nlaw `snapshot` is definition is value true = recorded "shape" end end';
  for(const wording of ['value true must be','value true is','value true =','value true must =','must value true =']) {
    const after='function value (flag :: Bool) -> Bool is flag end function\nlaw "|snapshot| is definition: '+wording+' recorded "shape" end end';
    const result=await compare(before,after);
    assert.equal(result.status,'matched');
    assert.equal(result.lawBodies.status,'matched');
  }
});

test('intrinsic ordered-key invariants are checked through types, while map values may use the transport',async()=>{
  for(const [beforeType,afterType] of [['Set Capsule','SortedSet Capsule'],['KeyVal Capsule Bool','KeyVal Capsule Bool']]) {
    const before=oldType+'definition keep (input :: '+beforeType+') :: '+beforeType+' is input end';
    const after=newType+'function keep (input :: '+afterType+') -> '+afterType+' is input end function';
    const result=await compare(before,after);
    assert.equal(result.status,'not-established');
    assert.ok(result.reason.includes('intrinsic sortedness'),result.reason);
  }
  const before=oldType+'definition keep (input :: KeyVal Text Capsule) :: KeyVal Text Capsule is input end';
  const after=newType+'function keep (input :: KeyVal Text Capsule) -> KeyVal Text Capsule is input end function';
  const result=await compare(before,after);
  assert.equal(result.status,'matched',JSON.stringify(result));
});
