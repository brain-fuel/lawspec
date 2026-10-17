// Generated from templates/npm/test/migration-collections.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';
import {migrationReport} from '../migrate.mjs';

const compiler=await createCompiler();
const options={schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:['exhaustive','examples']}};
async function migrate(sources,machineBits=64) {
  const before=await compiler.migrationBaseline({...options,from:'0.24',sources,machineBits});
  assert.deepEqual(before.diagnostics,[]);
  const report=await migrationReport(compiler,{version:1,targets:[]},{sources,machineBits});
  assert.deepEqual(report.diagnostics,[]);
  assert.deepEqual(report.sourcePreview.diagnostics,[]);
  assert.equal(report.sourcePreview.canonicalCheck.status,'accepted',JSON.stringify(report.sourcePreview.canonicalCheck));
  const migrated=report.sourcePreview.sources.map(({path,content})=>({path,content}));
  const after=await compiler.check({...options,sources:migrated,machineBits});
  assert.deepEqual(after.diagnostics,[]);
  for(const result of [before,after]) for(const law of result.evidence.filter(item=>item.stage==='law'))
    assert.equal(law.status,'exhaustively-checked');
  for(const source of report.sourcePreview.sources) for(const segment of source.segments.filter(segment=>segment.retained))
    assert.equal(source.content.slice(segment.start,segment.end),sources.find(input=>input.path===source.path).content.slice(segment.originalStart,segment.originalEnd));
  assert.equal(report.validation.lawVerification,'not-established-by-migration');
  assert.deepEqual(report.filesWritten,[]);
  return {before,after,report,sources:migrated};
}

const ordered=await readFile(new URL('../../test/fixtures/migration-collections-0.24.lawspec',import.meta.url),'utf8');

test('legacy sets retain sorted iteration, duplicate removal and every ordered operation at both widths',async()=>{
  for(const machineBits of [32,64]) {
    const {sources,report}=await migrate([{path:'ordered.lawspec',content:ordered}],machineBits);
    const content=sources[0].content;
    for(const suffix of ['Of','Member','Insert','Remove','Union','Intersection','Difference'])
      assert.ok(content.includes('prelude.sortedSet'+suffix),suffix);
    assert.ok(content.includes('SortedSet Integer'));
    assert.ok(report.baseline.sourceSyntax[0].references.some(reference=>reference.name==='prelude.member'&&reference.declaration==='lawspec.collections::setMember'));
    const mutant=await compiler.check({...options,machineBits,sources:[{...sources[0],content:content.replace('sortedSetOf','setOf')}]});
    assert.ok(mutant.diagnostics.length,'Using the new Eq set must not pass as the preserved sorted set');
  }
});

test('collection import lists, qualified references and facade exports use the original declaration identity',async()=>{
  const sources=[
    {path:'facade.lawspec',content:'unit facade\nimport lawspec.collections as ordered (Set, setOf, setMember)\nexport ordered.Set, ordered.setOf, ordered.setMember'},
    {path:'consumer.lawspec',content:'unit consumer\nimport facade as old (Set, setOf, setMember)\n'+
      'definition make (values :: List Integer) :: old.Set Integer is old.setOf values end\n'+
      'law `membership` is definition is old.setMember 2 (make [2, 1]) = true end end'},
  ];
  for(const bits of [32,64]) {
    const migrated=await migrate(bits===32?[...sources].reverse():sources,bits);
    const facade=migrated.sources.find(source=>source.path==='facade.lawspec').content;
    const consumer=migrated.sources.find(source=>source.path==='consumer.lawspec').content;
    assert.ok(facade.includes('(SortedSet, sortedSetOf, sortedSetMember)'));
    assert.ok(facade.includes('export ordered.SortedSet, ordered.sortedSetOf, ordered.sortedSetMember'));
    assert.ok(consumer.includes('(SortedSet, sortedSetOf, sortedSetMember)'));
    assert.ok(consumer.includes('old.sortedSetOf values'));
    assert.ok(consumer.includes('old.SortedSet Integer'));
  }
});

test('same-spelled user declarations and bound operations are preserved while actual library references migrate',async()=>{
  const sources=[
    {path:'storage.lawspec',content:'unit storage\nshape :: Set Integer -> Set Integer'},
    {path:'model.lawspec',content:'unit model\ndefinition setOf (value :: Bool) :: Bool is value end'},
    {path:'facade.lawspec',content:'unit facade\nimport model as original\nexport original.setOf'},
    {path:'shadow.lawspec',content:'unit shadow\nimport facade as own\nimport lawspec.collections as library\n'+
      'type Set is Set flag :: Bool end\n'+
      'definition setOf (value :: Bool) :: Bool is own.setOf value end\n'+
      'definition custom (value :: Bool) :: Set is Set (setOf value) end\n'+
      'definition applied (setOf :: Bool) :: Bool is setOf end\n'+
      'definition actual (values :: List Integer) :: library.Set Integer is (library.setOf) values end\n'+
      'law `names` is definition is `for all` (value :: Bool) . applied value = value and custom value = Set value end end'},
  ];
  const migrated=await migrate(sources);
  const content=migrated.sources.find(source=>source.path==='shadow.lawspec').content;
  assert.ok(content.includes('function setOf (value :: Bool) -> Bool is own.setOf value'));
  assert.ok(content.includes('(setOf :: Bool) -> Bool is setOf'));
  assert.ok(content.includes('-> Set is Set record{'));
  assert.ok(content.includes('-> library.SortedSet Integer is (library.sortedSetOf) values'));
  const references=migrated.report.baseline.sourceSyntax.find(source=>source.unit==='shadow').references;
  assert.ok(references.some(reference=>reference.name==='own.setOf'&&reference.declaration==='model::setOf'));
  assert.equal(references.filter(reference=>reference.name==='library.setOf').length,1);
});

test('BigUInt becomes Whole without changing bounded predicates',async()=>{
  const sources=[
    {path:'numbers.lawspec',content:'unit numbers\n'+
      'refinement Small is (n :: BigUInt where n <= 7) end\n'+
      'definition same (value :: BigUInt) :: BigUInt is value end\n'+
      'definition limited (value :: Small) :: Small is value end\n'+
      'law `bounded identity` is definition is limited 0 = 0 and limited 7 = 7 and same 0 = 0 end end'},
  ];
  for(const bits of [32,64]) {
    const migrated=await migrate(sources,bits);
    const numeric=migrated.sources.find(source=>source.path==='numbers.lawspec').content;
    assert.ok(numeric.includes('n :: Whole where n <= 7'));
    assert.ok(numeric.includes('(value :: Whole) -> Whole'));
    for(const input of [sources,migrated.sources]) {
      const rejected=await compiler.check({...options,schemaVersion:input===migrated.sources?5:3,machineBits:bits,
        sources:input.map(source=>({...source,content:source.content.replace('limited 7 = 7','limited 8 = 8')}))});
      assert.ok(rejected.diagnostics.some(diagnostic=>diagnostic.code==='refuted'&&diagnostic.message.includes('precondition failed')),
        'The original upper bound must still reject 8 at the checked function boundary');
    }
  }
});

// This shadow is valid legacy source, but the current canonical grammar reserves
// legacy numeric spellings. Retain its meaning and report that remaining blocker.
test('a legacy refinement named BigUInt is retained and its canonical spelling conflict remains visible',async()=>{
  const source={path:'shadow.lawspec',content:'unit shadow\nrefinement BigUInt is UInt8 end\n'+
      'definition same (value :: BigUInt) :: BigUInt is value end\n'+
      'law `identity` is definition is `for all` (value :: BigUInt) . same value = value end end'};
  const report=await migrationReport(compiler,{version:1,targets:[]},{sources:[source]});
  assert.deepEqual(report.diagnostics,[]);
  assert.deepEqual(report.sourcePreview.diagnostics,[]);
  assert.ok(report.sourcePreview.sources[0].content.includes('(value :: BigUInt) -> BigUInt'));
  assert.equal(report.sourcePreview.canonicalCheck.status,'rejected');
  assert.ok(report.sourcePreview.canonicalCheck.diagnostics.some(diagnostic=>diagnostic.code==='parse'));
  assert.equal(report.validated,false);
  assert.deepEqual(report.filesWritten,[]);
});

test('canonical let delimiters preserve nested bindings and membership on native-width profiles',async()=>{
  const content='unit bindings\nlaw nested is definition: for all (value :: Bool) => '+
    'let outer = let inner = value in inner in '+
    'let present = (outer in [value]) in present = true and outer in [value] end end end';
  for(const machineBits of [32,64]) {
    const checked=await compiler.check({...options,machineBits,sources:[{path:'bindings.lawspec',content}]});
    assert.deepEqual(checked.diagnostics,[]);
    assert.equal(checked.evidence.find(item=>item.stage==='law').status,'exhaustively-checked');
    const rejected=await compiler.check({...options,machineBits,sources:[{path:'bindings.lawspec',content:content.replace('let inner = value','let inner = not value')}]});
    assert.ok(rejected.diagnostics.some(diagnostic=>diagnostic.code==='refuted'));
  }
});
