import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createCompiler} from '../api.mjs';

const source = {path:'templates.lawspec',content:'unit templates\n-- handler fake for Ability is end\n' +
  'definition identity (value :: a) :: a is value end\n' +
  'law `same` (operation :: a -> a) requires Eq a is definition is `for all` (value :: a) . operation value = value end end\n'};
const request = machineBits => ({schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]},from:'0.24',machineBits,sources:[source]});

test('migration syntax inventories unused templates without inventing executable definitions or verification', async () => {
  const compiler = await createCompiler();
  for (const bits of [32,64]) {
    const result = await compiler.migrationBaseline(request(bits));
    assert.deepEqual(result.diagnostics, []);
    assert.equal(result.sourceLanguageProfile,'0.24');
    assert.equal(result.verification.selection,'no-selected-checks');
    assert.equal(result.verification.intrinsicDefinitionChecks,true);
    assert.deepEqual(result.definitions,[]);
    assert.deepEqual(result.laws,[]);
    assert.equal(result.sourceSyntax.length,1);
    assert.equal(result.sourceSyntax[0].version,1);
    assert.deepEqual(result.sourceSyntax[0].bindings,[
      {namespace:'value',name:'identity',target:'templatesIdentity',declaration:'templates::identity'},
      {namespace:'law',name:'same',target:'same (templates)'},
    ]);
    assert.deepEqual(result.sourceSyntax[0].references,[]);
    const nodes = result.sourceSyntax[0].nodes;
    assert.ok(nodes.some(node => node.kind === 'declaration.definition' && node.name === 'identity' && node.uses.length === 0));
    assert.ok(nodes.some(node => node.kind === 'declaration.law' && node.name === 'same'));
    assert.ok(nodes.some(node => node.kind === 'quantifier.forall'));
    assert.ok(!nodes.some(node => node.kind === 'declaration.handler'));
    assert.equal(new Set(nodes.map(node => JSON.stringify(node))).size,nodes.length);
  }
});

test('legacy syntax entry and its cache cannot bypass canonical grammar or mandatory definition checks', async () => {
  const compiler = await createCompiler();
  const input = request(64);
  const first = await compiler.migrationBaseline(input);
  assert.deepEqual(first.diagnostics, []);
  assert.ok((await compiler.check(input)).diagnostics.length > 0);
  assert.deepEqual(await compiler.migrationBaseline(input),first);
  for (const change of [{schemaVersion:4},{from:'0.23'},{from:undefined}])
    assert.ok((await compiler.migrationBaseline({...input,...change})).diagnostics.length > 0);
  const invalid = await compiler.migrationBaseline({...input,sources:[{path:'invalid.lawspec',content:
    'unit invalid\ndefinition invalid (unused :: a) :: Integer is 1 / 0 end'}]});
  assert.ok(invalid.diagnostics.some(diagnostic => diagnostic.code === 'total'));
  assert.equal(invalid.sourceSyntax,undefined);
  const unselected = await compiler.migrationBaseline({...input,sources:[{path:'false.lawspec',content:
    'unit selected\nlaw `false` is definition is false end end'}]});
  assert.deepEqual(unselected.diagnostics, []);
  assert.equal(unselected.evidence.find(item => item.stage === 'law').status,'not-verified');
});

test('standalone harness syntax uses actual line-scoped parsing and original source positions', async () => {
  const compiler = await createCompiler();
  const sources = [
    {path:'unit.lawspec',content:'unit configured\nf :: Bool -> Bool\nlaw `identity` is definition is `for all` (value :: Bool) . f value = value end end'},
    {path:'harness.lawspec',content:'harness settings for configured is\nfor law `identity`\n  label if value then "enabled" else "disabled"\nend\n'},
  ];
  const result = await compiler.migrationBaseline({...request(64),sources});
  assert.deepEqual(result.diagnostics, []);
  assert.deepEqual(result.sourceSyntax.map(item => item.path),['unit.lawspec','harness.lawspec']);
  const harness = result.sourceSyntax[1];
  assert.equal(harness.unit,'configured');
  const conditional = harness.nodes.find(node => node.kind === 'if');
  assert.deepEqual(conditional.span.start,{file:'harness.lawspec',line:3,column:9});
  assert.ok(harness.nodes.some(node => node.kind === 'harness' && node.name === 'settings'));
});
