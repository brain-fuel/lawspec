// Generated from templates/npm/test/migration-laws.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createCompiler} from '../api.mjs';
import {migrationReport} from '../migrate.mjs';
import {MigrationDocument} from '../migration-source.mjs';

const compiler = await createCompiler();
const canonical = {schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]}};

// Canonical selection binds its scrutinee once. For these pure fixtures its
// single selector use is exactly the legacy match. Compare that form and
// alpha-rename pattern locals while retaining their types and positions.
function caseMeaning(value,locals=new Map(),path='root') {
  if (Array.isArray(value)) return value.map((item,index)=>caseMeaning(item,locals,path+'.'+index));
  if (!value || typeof value!=='object') return typeof value==='string' ? locals.get(value)??value : value;
  const node = value.node;
  if (node?.kind==='let' && node.body.node.kind==='match' && node.body.node.value.node.kind==='local' &&
      node.body.node.value.node.id===node.binder.id) {
    let uses=0;
    const count = item => {
      if (!item || typeof item!=='object') return;
      if (item.node?.kind==='local' && item.node.id===node.binder.id) uses++;
      Object.values(item).forEach(child=>Array.isArray(child)?child.forEach(count):count(child));
    };
    count(node.body);
    assert.equal(uses,1,'the introduced selection binder is used exactly once');
    assert.deepEqual(value.type,node.body.type);
    return caseMeaning({...value,node:{...node.body.node,value:node.value}},locals,path);
  }
  if (node?.kind==='match') {
    const cases = node.cases.map((branch,index)=>{
      const inner = new Map(locals);
      const binders = branch.binders.map((binder,number)=>{
        const id=path+'.case'+index+'.binder'+number;
        inner.set(binder.id,id);
        return {...binder,id,name:'bound'+number};
      });
      return {...branch,binders,body:caseMeaning(branch.body,inner,path+'.case'+index)};
    });
    return {...value,node:{...node,value:caseMeaning(node.value,locals,path+'.selector'),cases}};
  }
  return Object.fromEntries(Object.entries(value).map(([key,item])=>[key,caseMeaning(item,locals,path+'.'+key)]));
}

// This is a test projection, not the project correspondence validator. It
// accounts explicitly for law-name delimiter changes, source positions,
// rendered traces and associative conjunction grouping. Domain policy is
// checked separately below and remains an explicit migration blocker.
function meaning(value, names) {
  if (Array.isArray(value)) return value.map(item => meaning(item,names));
  if (value && typeof value === 'object') {
    if (value.kind === 'all') {
      const flatten = item => item.kind === 'all' ? item.items.flatMap(flatten) : [meaning(item,names)];
      return {kind:'all',items:value.items.flatMap(flatten)};
    }
    return Object.fromEntries(Object.entries(value)
      .filter(([key]) => !['origin','text','location','trace','inputDomain'].includes(key))
      .map(([key,item]) => [key,meaning(item,names)]));
  }
  if (typeof value === 'string') {
    if (names.has(value)) return names.get(value);
    for (const [name,renamed] of names) if (value.startsWith(name+'::')) return renamed+value.slice(name.length);
  }
  return value;
}
async function migrate(sources,machineBits=64) {
  const before = await compiler.migrationBaseline({...canonical,from:'0.24',sources,machineBits});
  assert.deepEqual(before.diagnostics,[]);
  const report = await migrationReport(compiler,{version:1,targets:[]},{sources,machineBits});
  assert.deepEqual(report.diagnostics,[]);
  assert.deepEqual(report.sourcePreview.diagnostics,[]);
  assert.equal(report.sourcePreview.canonicalCheck.status,'accepted');
  assert.equal(report.sourcePreview.canonicalCheck.intrinsicDefinitionChecks,true);
  assert.equal(report.sourcePreview.canonicalCheck.lawVerification,'no-selected-checks');
  const migrated = report.sourcePreview.sources.map(({path,content}) => ({path,content}));
  const after = await compiler.check({...canonical,sources:migrated,machineBits});
  assert.deepEqual(after.diagnostics,[],migrated.map(source=>source.content).join('\n'));
  const names = new Map();
  const renamed = name => '"|'+name.replace(/[\\|]/g,character=>'\\'+character)+'|';
  for (const law of before.laws) {
    names.set(law.id,law.owner+'::law::'+renamed(law.name));
    law.name = renamed(law.name);
    for (const example of law.examples) {
      const named = before.sourceSyntax.flatMap(source=>source.nodes)
        .some(node=>node.kind==='example' && node.name===example.name);
      if (named) example.name = renamed(example.name);
    }
    const migratedLaw = after.laws.find(item=>item.id===names.get(law.id));
    assert.equal(law.inputDomain,'nonempty');
    assert.equal(migratedLaw.inputDomain,'universal');
    assert.equal(migratedLaw.trace[0],law.name);
  }
  for (const key of ['definitions','contracts','laws'])
    assert.deepEqual(meaning(caseMeaning(after[key]),new Map()),meaning(caseMeaning(before[key]),names),key);
  const ownedUnit = unit => before.sourceSyntax.some(source=>unit.id===source.unit);
  assert.deepEqual(meaning(after.units.filter(ownedUnit),new Map()),meaning(before.units.filter(ownedUnit),names),'source-owned units');
  const ownedType = type => before.sourceSyntax.some(source=>type.id.startsWith(source.unit+'::'));
  assert.deepEqual(meaning(after.dataTypes.filter(ownedType),new Map()),meaning(before.dataTypes.filter(ownedType),names),'source-owned data types');
  for (const source of report.sourcePreview.sources) {
    const original = sources.find(item=>item.path===source.path).content;
    for (const segment of source.segments.filter(segment=>segment.retained))
      assert.equal(source.content.slice(segment.start,segment.end),original.slice(segment.originalStart,segment.originalEnd));
  }
  assert.equal(report.validation.lawVerification,'not-established-by-migration');
  assert.equal(report.domainPolicyChanges.length,before.laws.length);
  const domainPending=report.correspondence.domainPolicies.status!=='matched'||
    report.correspondence.sourceTemplates.domainPolicies?.status==='not-established';
  assert.equal(report.blockers.some(blocker=>blocker.includes('empty-domain')),domainPending);
  assert.deepEqual(report.filesWritten,[]);
  return {before,after,report,sources:migrated};
}

test('law previews preserve dependent restrictions, nested universal scopes, conjunction and implication', async () => {
  const source = {path:'scopes.lawspec',content:'unit scopes\n' +
    'definition identity (value :: Bool) :: Bool is value end\n' +
    'law `nested` is definition is `for all` (left :: Bool) . `for all` (right :: Bool where right == left) . '+
    'left == right implies identity left = right and identity right = left end end\n' +
    'law `conjunction` is definition is `for all` (value :: Bool) . identity value = value and identity value = value and identity value = value end end\n'};
  for (const bits of [32,64]) {
    const {sources} = await migrate([source],bits);
    assert.equal((sources[0].content.match(/for all/g)||[]).length,3);
    assert.equal((sources[0].content.match(/=>/g)||[]).length,3);
    assert.ok(sources[0].content.includes('end end end end'));
    const selected = await compiler.check({...canonical,verification:{layers:['exhaustive']},sources,machineBits:bits});
    assert.deepEqual(selected.diagnostics,[]);
    assert.ok(selected.evidence.filter(item=>item.stage==='law').every(item=>item.status==='exhaustively-checked'));
  }
});

test('table previews preserve multiple expectations, recorded values, comments, literals and origin segments', async () => {
  const source = {path:'tables.lawspec',content:'unit tables\r\n' +
    'definition identity (value :: Bool) :: Bool is value end\r\n' +
    'law `table` is\r\n definition is `for all` (value :: Bool) . identity value = value end\r\n' +
    ' description is "end table is documentary" end\r\n rationale is "Keep both checks." end\r\n' +
    ' table (value, expected) is\r\n  row true, true -- retained row comment 😀\r\n  row false, false\r\n' +
    '  expect (if value then true else false) = expected -- moved expectation comment\r\n' +
    '  expect identity value = recorded "|answer"\r\n end\r\n' +
    ' references are "https://example.org/end" end\r\nend\r\n'};
  for (const bits of [32,64]) {
    const {before,after,sources} = await migrate([source],bits);
    assert.equal(after.laws[0].examples.length,2);
    assert.equal(after.laws[0].examples[0].expectations.length,2);
    assert.equal(before.laws[0].examples[0].expectations.length,2);
    assert.ok(sources[0].content.indexOf('expect ') < sources[0].content.indexOf('in table'));
    assert.ok(sources[0].content.includes('-- moved expectation comment\r\n'));
    assert.ok(sources[0].content.includes('-- retained row comment 😀\r\n'));
    assert.ok(sources[0].content.includes('recorded "\\124answer"'));
    assert.ok(!sources[0].content.replaceAll('\r\n','').includes('\n'));
  }
});

test('law import, facade export, qualified reuse and standalone harness selection migrate together', async () => {
  const sources = [
    {path:'base.lawspec',content:'unit base\nlaw `same` (operation :: a -> a) requires Eq a is definition is `for all` (value :: a) . operation value = value end end'},
    {path:'facade.lawspec',content:'unit facade\nimport base as base (`same`)\nexport `same`'},
    {path:'use.lawspec',content:'unit use\nimport facade as rules (`same`)\ndefinition identity (value :: Bool) :: Bool is value end\n'+
      'law `identity` is definition is rules.`same` identity end end'},
    {path:'harness.lawspec',content:'harness configured for use is\nfor law `identity`\n label if value then "enabled" else "disabled"\nend'},
  ];
  const result = await migrate(sources);
  assert.ok(result.sources[1].content.includes('import base as base (law "|same|)'));
  assert.ok(result.sources[1].content.includes('export law "|same|'));
  assert.ok(result.sources[2].content.includes('apply law rules."|same| identity'));
  assert.ok(result.sources[3].content.includes('for law "|identity|'));
  assert.ok(result.sources[3].content.includes('else "disabled" end if'));
  assert.deepEqual(result.after.laws[0].trace,['"|identity|','"|same| (base) identity']);
});

test('phrase-name escaping and named examples preserve spelling without rewriting literal contents', async () => {
  const source = {path:'names.lawspec',content:'unit names\nf :: Text -> Text\n'+
    'law `x|y\\z` is definition is `for all` (value :: Text) . f value = value end\n'+
    'example `pipe|slash\\name` is value = "x|y\\\\z" expect f value = "x|y\\\\z" end end'};
  const {sources,after} = await migrate([source]);
  assert.ok(sources[0].content.includes('law "|x\\|y\\\\z| is'));
  assert.ok(sources[0].content.includes('example "|pipe\\|slash\\\\name| :'));
  assert.equal(after.laws[0].examples[0].name,'"|pipe\\|slash\\\\name|');
});

test('case previews preserve nested selection, constructor bindings, recursion and finite outcomes', async () => {
  const source = {path:'cases.lawspec',content:'unit cases\n' +
    'type Choice is | First | Second end\n' +
    'definition flip (value :: Choice) :: Choice is match value with | First -> Second | Second -> First end end\n' +
    'definition nested (value :: Choice) :: Choice is match match value with | First -> Second | Second -> First end with '+
      '| First -> Second | Second -> First end end\n' +
    'definition copy (values :: List Choice) :: List Choice is match values with | Nil -> [] | Cons value rest -> Cons value (copy rest) end end\n' +
    'law `twice` is definition is `for all` (value :: Choice) . flip (flip value) = value and nested value = value end '+
      'table (value, expected) is row First, First row Second, Second expect nested value = expected end end\n' +
    'law `copy` is definition is `for all` (values :: List Choice) . copy values = values end '+
      'table (values, expected) is row [], [] row [First, Second, First], [First, Second, First] expect copy values = expected end end'};
  for (const bits of [32,64]) {
    const {sources,after} = await migrate([source],bits);
    assert.ok(sources[0].content.includes('type Choice is one of'));
    assert.equal((sources[0].content.match(/end case/g)||[]).length,4);
    assert.equal(after.laws.reduce((count,law)=>count+law.examples.length,0),4);
    const selected = await compiler.check({...canonical,verification:{layers:['exhaustive','examples']},sources,machineBits:bits});
    assert.deepEqual(selected.diagnostics,[]);
    assert.equal(selected.evidence.find(item=>item.declaration.endsWith('"|twice|')&&item.stage==='law').status,'exhaustively-checked');
    const mutant = sources.map(source=>({...source,content:source.content.replace('when Second then First','when Second then Second')}));
    const uncheckedLaws = await compiler.check({...canonical,sources:mutant,machineBits:bits});
    assert.deepEqual(uncheckedLaws.diagnostics,[]);
    assert.equal(uncheckedLaws.verification.intrinsicDefinitionChecks,true);
    assert.equal(uncheckedLaws.evidence.find(item=>item.stage==='law').status,'not-verified');
    const refuted = await compiler.check({...canonical,verification:{layers:['exhaustive']},sources:mutant,machineBits:bits});
    assert.ok(refuted.diagnostics.some(diagnostic=>diagnostic.code==='refuted'));
  }
});

test('a grouped natural-index payload preview keeps canonical rejection separate from planning and validation', async () => {
  const content = 'unit payload\ntype Chain (n :: Natural) is | Stop where n = 0 '+
    '| Next marker :: Bool rest :: Chain m where n = m + 1 end\n';
  const report = await migrationReport(compiler,{version:1,targets:[]},{sources:[{path:'payload.lawspec',content}]});
  assert.deepEqual(report.diagnostics,[]);
  assert.deepEqual(report.sourcePreview.diagnostics,[]);
  assert.equal(report.sourcePreview.canonicalCheck.status,'rejected');
  assert.ok(report.sourcePreview.canonicalCheck.diagnostics.length>0);
  assert.ok(report.blockers.some(blocker=>blocker.includes('canonical compilation')));
  assert.equal(report.validated,false);
  assert.deepEqual(report.filesWritten,[]);
});

test('preview rejects implicit name trimming and expectation-free tables without enabling writes', async () => {
  for (const content of [
    'unit names\nf :: Bool -> Bool\nlaw ` edge ` is definition is `for all` (value :: Bool) . f value = value end end',
    'unit tables\nf :: Bool -> Bool\nlaw `identity` is definition is `for all` (value :: Bool) . f value = value end table (value) is row true end end',
    'unit capture\ntype Choice is | Enabled | Disabled end\ndefinition choose (it :: Bool) (value :: Choice) :: Bool is match value with | Enabled -> it | Disabled -> false end end',
  ]) {
    const report = await migrationReport(compiler,{version:1,targets:[]},{sources:[{path:'decision.lawspec',content}]});
    assert.deepEqual(report.diagnostics,[]);
    assert.equal(report.sourcePreview.diagnostics[0].code,'migration-source');
    assert.equal(report.sourcePreview.sources.length,0);
    assert.equal(report.validated,false);
    assert.deepEqual(report.filesWritten,[]);
  }
});

test('relocated ranges reject crossing edits and preserve original coordinates for retained source', () => {
  const document = new MigrationDocument({path:'source',content:'table rows expect value == true end'});
  document.edit(24,26,'=','typed equality');
  document.moveBefore(11,32,0,'expectation-first table');
  const result = document.result();
  assert.equal(result.content,'expect value = true table rows end');
  for (const segment of result.segments.filter(segment=>segment.retained))
    assert.equal(result.content.slice(segment.start,segment.end),document.content.slice(segment.originalStart,segment.originalEnd));
  const crossing = new MigrationDocument({path:'source',content:'abcdef'});
  crossing.edit(2,4,'x','crossing');
  assert.throws(()=>crossing.moveBefore(3,5,0,'move'),/Overlapping/);
});
