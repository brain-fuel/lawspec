import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createCompiler} from '../api.mjs';
import {migrationReport} from '../migrate.mjs';

const compiler = await createCompiler();
const options = {schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:['exhaustive','examples']}};
async function migrate(content,machineBits=64) {
  const sources=[{path:'records.lawspec',content}];
  const before=await compiler.migrationBaseline({...options,from:'0.24',sources,machineBits});
  assert.deepEqual(before.diagnostics,[]);
  const report=await migrationReport(compiler,{version:1,targets:[]},{sources,machineBits});
  assert.deepEqual(report.diagnostics,[]);
  assert.deepEqual(report.sourcePreview.diagnostics,[]);
  assert.equal(report.sourcePreview.canonicalCheck.status,'accepted',JSON.stringify(report.sourcePreview.canonicalCheck));
  const migrated=report.sourcePreview.sources.map(({path,content})=>({path,content}));
  const after=await compiler.check({...options,sources:migrated,machineBits});
  assert.deepEqual(after.diagnostics,[],migrated[0].content);
  for(const result of [before,after]) assert.ok(result.evidence.filter(item=>item.stage==='law').every(item=>item.status==='exhaustively-checked'));
  for(const file of report.sourcePreview.sources) for(const segment of file.segments.filter(segment=>segment.retained))
    assert.equal(file.content.slice(segment.start,segment.end),content.slice(segment.originalStart,segment.originalEnd));
  assert.equal(report.validated,false);
  assert.deepEqual(report.filesWritten,[]);
  return {before,after,report,sources:migrated};
}

test('nominal records retain field identities while nested construction, patterns and literals acquire braces', async () => {
  const content='unit records\n'+
    'type Inner is | Inner left :: Bool right :: Bool end\n'+
    'type Outer is Outer inner :: Inner other :: Bool end\n'+
    'definition create (value :: Bool) :: Outer is Outer (Inner value false) true end\n'+
    'definition read (value :: Outer) :: Bool is match value with | Outer inner other -> match inner with | Inner left right -> left end end end\n'+
    'law `round trip` is definition is `for all` (value :: Bool) . read (create value) = value end '+
    'table (value, expected) is row true, (Outer (Inner true false) true) row false, (Outer (Inner false false) true) expect create value = expected end end';
  for(const bits of [32,64]) {
    const {before,after,sources,report}=await migrate(content,bits);
    const graph=result=>result.dataTypes.filter(type=>type.id.startsWith('records::')).map(type=>({id:type.id,constructors:type.constructors.map(constructor=>({id:constructor.id,fields:constructor.fields}))}));
    assert.deepEqual(graph(after),graph(before));
    assert.ok(sources[0].content.includes('type Inner is a record{'));
    assert.ok(sources[0].content.includes('(Inner record{'));
    assert.ok(sources[0].content.includes('when Outer record{'));
    assert.ok(report.constructorChanges.every(change=>change.change.includes('preserve its constructor field binding')));
    const mutant=sources.map(source=>({...source,content:source.content.replace('left = value','left = not value')}));
    const rejected=await compiler.check({...options,sources:mutant,machineBits:bits});
    assert.ok(rejected.diagnostics.some(diagnostic=>diagnostic.code==='refuted'));
  }
});

test('local alternatives retain zero/single arities and explicitly group multiple payload fields', async () => {
  const content='unit records\n'+
    'type Variant is | Empty | Single flag of type Bool | Double left :: Bool right :: Bool end\n'+
    'definition flip (value :: Variant) :: Variant is match value with | Empty -> Empty | Single flag -> Single flag | Double left right -> Double right left end end\n'+
    'law `twice` is definition is `for all` (value :: Variant) . flip (flip value) = value end '+
    'table (value, expected) is row Empty, Empty row Single true, Single true row (Double true false), (Double false true) expect flip value = expected end end';
  for(const bits of [32,64]) {
    const {after,sources}=await migrate(content,bits);
    const type=after.dataTypes.find(type=>type.name==='Variant');
    assert.deepEqual(type.constructors.map(constructor=>constructor.fields.length),[0,1,1]);
    assert.ok(sources[0].content.includes('Single  of type Bool'));
    assert.ok(sources[0].content.includes('Double of type record{'));
    assert.ok(sources[0].content.includes('when Double record{'));
  }
});

function layered(mask) {
  const types=['Leaf','Middle','Root'];
  const constructor=index=>(mask&(1<<index))?'Has'+types[index]:types[index];
  const declarations=types.map((name,index)=>'type '+name+' is '+((mask&(1<<index))?'| No'+name+' | ':'')+constructor(index)+
    ' value :: '+(index?types[index-1]:'Bool')+' retained :: Bool end');
  const readers=types.map((name,index)=>'definition read'+name+' (input :: '+name+') :: Bool is match input with '+
    ((mask&(1<<index))?'| No'+name+' -> false ':'')+'| '+constructor(index)+' value retained -> '+(index?'read'+types[index-1]+' value':'value')+' end end');
  const encoded=constructor(2)+' ('+constructor(1)+' ('+constructor(0)+' value true) true) true';
  return 'unit records\n'+declarations.join('\n')+'\n'+readers.join('\n')+'\n'+
    'definition encode (value :: Bool) :: Root is '+encoded+' end\n'+
    'law `round trip` is definition is `for all` (value :: Bool) . readRoot (encode value) = value end '+
      'table (value, expected) is row true, true row false, false expect readRoot (encode value) = expected end end\n'+
    'law `every shape is readable` is definition is `for all` (input :: Root) . readRoot input = readRoot input end end';
}
for(let mask=0;mask<8;mask++) test('three nested record/alternative layers migrate with independent Boolean outcomes: '+mask,async()=>{
  for(const bits of [32,64]) {
    const {sources,after}=await migrate(layered(mask),bits);
    assert.equal(after.laws.length,2);
    assert.equal(after.laws[0].examples.length,2);
    assert.equal((sources[0].content.match(/ of type record\{/g)||[]).length,mask.toString(2).replaceAll('0','').length);
    const mutant=sources.map(source=>({...source,content:source.content.replace('then value end case','then not value end case')}));
    const rejected=await compiler.check({...options,sources:mutant,machineBits:bits});
    assert.ok(rejected.diagnostics.some(diagnostic=>diagnostic.code==='refuted'));
  }
});

test('record migration keeps comments and refines sibling fields through their original lexical names',async()=>{
  const content='unit records\n'+
    'type Pair is -- between declaration and constructor 😀\n | Pair -- before first field\n left :: UInt8 right :: (n :: UInt8 where n == left) end\n'+
    'definition create (value :: UInt8) :: Pair is Pair -- between constructor and first argument\n value value end\n'+
    'law `equal fields` is definition is `for all` (value :: UInt8) . (create value).left = (create value).right end end';
  const {sources}=await migrate(content);
  for(const comment of ['-- between declaration and constructor 😀','-- before first field','-- between constructor and first argument'])
    assert.ok(sources[0].content.includes(comment));
});

test('unused generic nominal records migrate before specialization and retain concrete projections when instantiated',async()=>{
  const template='unit records\n'+
    'type Pair (a :: Type) (b :: Type) is Pair first :: a second :: b end\n'+
    'definition pair (first :: a) (second :: b) :: Pair a b is Pair first second end\n'+
    'definition first (value :: Pair a b) :: a is match value with | Pair first second -> first end end';
  const generic=await migrate(template);
  assert.equal(generic.before.definitions.length,0);
  assert.equal(generic.after.definitions.length,0);
  assert.equal(generic.report.sourcePreview.canonicalCheck.intrinsicDefinitionChecks,true);
  for(const bits of [32,64]) {
    const {after}=await migrate(template+'\nlaw `first` is definition is `for all` (left :: Bool) (right :: Bool) . first (pair left right) = left end end',bits);
    assert.ok(after.definitions.some(definition=>definition.id.includes('pair')));
    assert.equal(after.laws.length,1);
  }
});

test('record and alternative payloads migrate through qualified imports, facades and same-spelled local constructors',async()=>{
  const sources=[
    {path:'model.lawspec',content:'unit model\ntype Pair is Pair first :: Bool second :: Bool end\n'+
      'type Output is | None | Result first :: Bool second :: Bool end'},
    {path:'facade.lawspec',content:'unit facade\nimport model as original (Pair, Output)\nexport Pair, Output'},
    {path:'use.lawspec',content:'unit use\nimport facade as models (Pair, Output)\n'+
      'definition make (value :: Bool) :: models.Pair is models.Pair value false end\n'+
      'definition read (value :: Pair) :: Bool is match value with | models.Pair first second -> first end end\n'+
      'definition answer (value :: Bool) :: Output is Result value false end\n'+
      'definition unpack (value :: Output) :: Bool is match value with | None -> false | models.Result first second -> first end end\n'+
      'law `pair` is definition is `for all` (value :: Bool) . read (make value) = value end '+
        'table (value, expected) is row false, (models.Pair false false) row true, Pair true false expect make value = expected end end\n'+
      'law `answer` is definition is `for all` (value :: Bool) . unpack (answer value) = value end end'},
    {path:'shadow.lawspec',content:'unit shadow\nimport facade as foreign\n'+
      'type Pair is Pair flag :: Bool end\n'+
      'definition local (value :: Bool) :: Pair is Pair value end\n'+
      'definition remote (value :: Bool) :: foreign.Pair is foreign.Pair value false end\n'+
      'definition remoteFirst (value :: foreign.Pair) :: Bool is match value with | foreign.Pair first second -> first end end\n'+
      'law `both` is definition is `for all` (value :: Bool) . local value = Pair value and remoteFirst (remote value) = value end end'},
  ];
  for(const machineBits of [32,64]) {
    const input=machineBits===32?[...sources].reverse():sources;
    const before=await compiler.migrationBaseline({...options,from:'0.24',sources:input,machineBits});
    assert.deepEqual(before.diagnostics,[]);
    const report=await migrationReport(compiler,{version:1,targets:[]},{sources:input,machineBits});
    assert.deepEqual(report.sourcePreview.diagnostics,[]);
    assert.equal(report.sourcePreview.canonicalCheck.status,'accepted',JSON.stringify(report.sourcePreview.canonicalCheck));
    const migrated=report.sourcePreview.sources.map(({path,content})=>({path,content}));
    const after=await compiler.check({...options,sources:migrated,machineBits});
    assert.deepEqual(after.diagnostics,[]);
    assert.equal(after.laws.length,3);
    assert.ok(after.evidence.filter(item=>item.stage==='law').every(item=>item.status==='exhaustively-checked'));
    const use=migrated.find(source=>source.path==='use.lawspec').content;
    const shadow=migrated.find(source=>source.path==='shadow.lawspec').content;
    assert.ok(use.includes('models.Pair record{ first = value , second = false}'));
    assert.ok(use.includes('when models.Result record{ first = first , second = second}'));
    assert.ok(shadow.includes('Pair record{ flag = value}'));
    assert.ok(shadow.includes('foreign.Pair record{ first = value , second = false}'));
    assert.equal(report.validated,false);
    assert.deepEqual(report.filesWritten,[]);
  }
});
