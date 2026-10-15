// Generated from templates/npm/test/expression-presentation.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { createTypePresentation } from '../typed-presentation.mjs';
import { explainLaw } from '../explain.mjs';

const integer = {kind: 'constructor', name: 'Integer', arguments: []};
const expression = (node, text = 'original checked term', type = integer) => ({node, text, type});
const local = (id, text = id) => expression({kind: 'local', id}, text);
const number = value => expression({kind: 'constant', value: {type: 'Integer', value: String(value)}}, String(value));
const unit = expression({kind: 'constant', value: {type: 'Unit'}}, 'unitValue');
const binder = (id, name = id) => ({id, name, type: integer});
const letIn = (binding, value, body) => expression({kind: 'let', binder: binding, value, body});
const binary = (operator, left, right) => expression({kind: 'binary', operator, left, right});
const construct = (constructor, ...arguments_) => expression({kind: 'construct', constructor, arguments: arguments_});
const record = (id, labels) => ({id, name: id, parameters: [], structure: {kind: 'record', fields: labels.map(name => ({name, predicates: []}))},
  constructors: [{id: id + '::Record', name: 'Record', fields: labels.map(name => binder(id + '::' + name, name))}]});
const functions = declarations => [{id: 'domain', declarations: declarations.map(name => ({id: 'domain::' + name, name}))}];
const call = (name, ...arguments_) => expression({kind: 'call', declaration: 'domain::' + name, arguments: arguments_});
const presentation = result => createTypePresentation(result).expressionText;

test('record reconstruction preserves evaluation order and every computation exactly once', () => {
  const result = {dataTypes: [record('pair', ['a', 'z'])], units: functions(['first', 'second'])};
  const term = letIn(binder('one', '_lawspecRecordField0'), call('first', unit),
    letIn(binder('two', '_lawspecRecordField1'), call('second', unit),
      construct('pair::Record', local('two'), local('one'))));
  const before = structuredClone(term);
  assert.equal(presentation(result)(term), 'record{z = first (), a = second ()}');
  assert.deepEqual(term, before);
});

test('dependent, reused and unused bindings remain explicit without capture', () => {
  const render = presentation({dataTypes: [record('pair', ['a', 'z'])]});
  const dependent = letIn(binder('a', 'x'), number(1),
    letIn(binder('b', 'x'), binary('+', local('a', 'x'), number(1)), construct('pair::Record', local('a'), local('b'))));
  assert.equal(render(dependent), 'let x = 1 in let x1 = (x + 1) in record{a = x, z = x1}');
  const reused = letIn(binder('a', 'x'), binary('/', number(1), number(0)), construct('pair::Record', local('a'), local('a')));
  assert.equal(render(reused), 'let x = (1 / 0) in record{a = x, z = x}');
  const unused = letIn(binder('a', 'x'), binary('/', number(1), number(0)), number(2));
  assert.equal(render(unused), 'let x = (1 / 0) in 2');
  const shadow = letIn(binder('inner', 'x'), number(2), binary('+', local('outer', 'x'), local('inner', 'x')));
  assert.equal(render(shadow), 'let x1 = 2 in (x + x1)');
  const phrase = letIn(binder('inner', '"|amount due|'), number(2), binary('+', local('outer', '"|amount due|'), local('inner', '"|amount due|')));
  assert.equal(render(phrase), 'let value1 = 2 in ("|amount due| + value1)');
});

test('projection presentation retains strict unselected fields in its subject', () => {
  const data = {id: 'domain::type::Box', constructors: [{id: 'Box', name: 'Box', fields: [binder('chosen'), binder('unused')]}]};
  const term = expression({kind: 'match', value: construct('Box', number(1), binary('/', number(1), number(0))),
    cases: [{constructor: 'Box', binders: [binder('one'), binder('two')], body: local('one')}]});
  assert.equal(presentation({dataTypes: [data]})(term), 'Box(chosen = 1, unused = (1 / 0)).chosen');
});

test('ordered cases and callback scopes keep distinct binders and all branches', () => {
  const data = {id: 'domain::type::Choice', constructors: ['Left', 'Right'].map(name => ({id: name, name, fields: [binder('value')]}))};
  const term = expression({kind: 'match', value: local('subject', 'choice'), cases: [
    {constructor: 'Left', binders: [binder('one', 'x')], body: binary('+', local('outside', 'x'), local('one', 'x'))},
    {constructor: 'Right', binders: [binder('two', 'x')], body: local('two', 'x')},
  ]});
  const render = presentation({dataTypes: [data]});
  assert.equal(render(term), 'case choice of {domain.Choice.Left(x1): (x + x1); domain.Choice.Right(x1): x1}');
  const product = expression({kind: 'match', value: local('pair'), cases: [{constructor: 'pair::Record',
    binders: [binder('one', 'a'), binder('two', 'z')], body: binary('+', local('one', 'a'), local('two', 'z'))}]});
  assert.equal(presentation({dataTypes: [record('pair', ['a', 'z'])]})(product), 'case pair of {record{a = a, z = z}: (a + z)}');
  const elements = expression({kind: 'allElements', value: local('items'), binder: binder('item', 'x'),
    predicate: binary('>', local('item', 'x'), local('outside', 'x'))});
  assert.equal(render(elements), 'every x1 in (items) satisfies ((x1 > x))');
  const payloads = expression({kind: 'allPayloads', value: local('items'), predicates: [
    {binder: binder('one', 'x'), predicate: binary('>', local('one', 'x'), local('outside', 'x'))},
    {binder: binder('two', 'x'), predicate: local('two', 'x')},
  ]});
  assert.equal(render(payloads), 'allPayloads (items) [x1 of type Integer => (x1 > x); x1 of type Integer => x1]');
});

test('global names resolve by identity with qualification and phrase spelling', () => {
  const render = presentation({units: [
    {id: 'first', declarations: [{id: 'f', name: 'send notice'}, {id: 'single', name: 'check'}]},
    {id: 'second', declarations: [{id: 'g', name: 'send notice'}]},
  ]});
  assert.equal(render(expression({kind: 'call', declaration: 'f', arguments: [unit]})), 'first."|send notice| ()');
  const shadowed = binary('+', local('input', 'check'), expression({kind: 'call', declaration: 'single', arguments: [unit]}));
  assert.equal(render(shadowed), '(check + (first.check ()))');
  const imported = presentation({units: [
    {id: 'owner', declarations: [{id: 'owner::check', name: 'check'}]},
    {id: 'importer', declarations: [{id: 'owner::check', name: 'check'}]},
  ]});
  assert.equal(imported(expression({kind: 'call', declaration: 'owner::check', arguments: []}), new Map([['input', 'check']])), 'owner.check');
  const alternatives = ['One', 'Two'].map(name => ({id: 'domain::type::' + name,
    constructors: [{id: name + '::Yes', name: 'Yes', fields: []}]}));
  const qualified = presentation({dataTypes: alternatives});
  assert.equal(qualified(construct('One::Yes')), 'domain.One.Yes');
  assert.equal(qualified(construct('Two::Yes')), 'domain.Two.Yes');
});

test('Boolean precedence, literal contents, conversions and effect modes stay explicit', () => {
  const render = presentation({});
  const negated = expression({kind: 'unary', operator: '!', argument: local('enabled')});
  assert.equal(render(binary('==', negated, local('other'))), '((not (enabled)) = other)');
  const text = expression({kind: 'constant', value: {type: 'Text', value: 'a == b'}}, '"a == b"');
  assert.equal(render(binary('==', text, text)), '("a == b" = "a == b")');
  for (const conversion of ['explicit', 'checked'])
    assert.equal(render(expression({kind: 'convert', conversion, argument: local('input')})), `${conversion} conversion of (input) to Integer`);
  const perform = expression({kind: 'perform', ability: 'Log', operation: 'write', arguments: [text]});
  assert.equal(render(perform), 'perform Log.write("a == b")');
  assert.equal(render(expression({kind: 'handle', handling: 'catchFailure', ability: 'Fail', body: perform})), 'catch failure of Fail in (perform Log.write("a == b"))');
  assert.equal(render(expression({kind: 'handle', handling: 'withHandler', ability: 'Log', handler: 'recording native', body: perform})),
    'handle (perform Log.write("a == b")) with recording native for Log');
  assert.equal(render(expression({kind: 'calls', ability: 'Log', operation: 'write', arguments: null})), 'calls of Log.write');
  assert.equal(render(expression({kind: 'calls', ability: 'Log', operation: 'write', arguments: []})), 'calls of Log.write with ()');
  const fields = presentation({dataTypes: [record('pair', ['a', 'z'])]});
  const load = expression({kind: 'helper', name: 'prelude.load', arguments: [unit]});
  assert.equal(fields(expression({kind: 'update', constructor: 'pair::Record', index: 1, value: load, field: number(7)})),
    '(prelude.load ()) with z = 7');
  assert.equal(render(expression({kind: 'if', condition: local('enabled'), then: perform, else: number(0)})),
    'if enabled then perform Log.write("a == b") else 0 end if');
});

test('unhandled terms fall back as a whole before any binder is renamed', () => {
  const child = expression({kind: 'future-node'}, 'x');
  const term = letIn(binder('x', '_lawspecTemporary'), number(1), child);
  term.text = 'original let _lawspecTemporary = 1 in opaque(_lawspecTemporary)';
  assert.equal(presentation({})(term), term.text);
  const call = expression({kind: 'call', declaration: 'unknown', arguments: [local('x')]}, 'original unknown call');
  assert.equal(presentation({})(call), call.text);
});

test('ability identities use checked source names and retain ambiguous or unresolved argument keys', () => {
  const units = [{id: 'one', declarations: [], abilities: [{id: 'one::ability::Gateway', name: 'Gateway'}]}];
  const term = expression({kind: 'perform', ability: 'one::ability::Gateway', operation: 'capture', arguments: [number(1)]});
  const before = structuredClone(term);
  assert.equal(presentation({units})(term), 'perform Gateway.capture(1)');
  const parameterized = {...term, node: {...term.node, ability: 'one::ability::Gateway(opaque::type::Payload)'}};
  assert.equal(presentation({units})(parameterized), 'perform Gateway(opaque::type::Payload).capture(1)');
  const ambiguous = [...units, {id: 'two', declarations: [], abilities: [{id: 'two::ability::Gateway', name: 'Gateway'}]}];
  assert.equal(presentation({units: ambiguous})(term), 'perform one.Gateway.capture(1)');
  assert.deepEqual(term, before);
});

test('actual parcel assertions use readable terms with the original obligations and evidence', async () => {
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  const content = await readFile(new URL('../../examples/rc1/parcel-measurements.lawspec', import.meta.url), 'utf8');
  const result = await compiler.check({schemaVersion: 5, languageProfile: '1.0-rc.1', verification: {layers: []},
    sources: [{path: 'parcel-measurements.lawspec', content}]});
  assert.deepEqual(result.diagnostics, []);
  const before = structuredClone(result), law = result.laws.find(law => law.id.endsWith('::sampleWeight'));
  assert.ok(law);
  for (const view of ['developer', 'business', 'formal']) {
    const shown = explainLaw(law, result, view);
    assert.match(shown.text, /sampleParcel \(\) (must be|=) Parcel\(details = record\{weight = Measurement\(reading = record\{value = 1\}\)\}\)/);
    assert.doesNotMatch(shown.text, /lawspec::structural|lawspecRecordView|_lawspecRecordField/);
    assert.equal(shown.assertion, law.assertion);
    assert.equal(shown.inputs, law.inputs);
    assert.deepEqual(shown.evidence, result.evidence.filter(item => item.declaration === law.id));
  }
  assert.match(explainLaw(law, result, 'evidence').text, /NOT-VERIFIED/);
  assert.deepEqual(result, before);
});

test('rendered structural assertions recompile with the same checked outcome and source field order', async () => {
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  const content = `unit display.order
function first (unused of type ()) -> Integer is 1 end function
function second (unused of type ()) -> Integer is 2 end function
law ordered is
  definition:
    record{z = first (), a = second ()} must be record{a = 2, z = 1}
  end
end
`;
  const request = {schemaVersion: 5, languageProfile: '1.0-rc.1', verification: {layers: ['exhaustive']},
    sources: [{path: 'order.lawspec', content}]};
  const result = await compiler.check(request);
  assert.deepEqual(result.diagnostics, []);
  const law = result.laws.find(law => law.id.endsWith('::ordered'));
  assert.ok(law);
  const text = explainLaw(law, result, 'business').text;
  assert.equal(text, 'record{z = first (), a = second ()} must be record{a = 2, z = 1}');
  const roundtrip = await compiler.check({...request, sources: [{path: 'order.lawspec', content:
    content + `\nlaw displayed is definition: ${text} end end\n`}]});
  assert.deepEqual(roundtrip.diagnostics, []);
  const rendered = roundtrip.laws.find(law => law.id.endsWith('::displayed'));
  assert.ok(rendered);
  assert.deepEqual(rendered.assertion.left.type, law.assertion.left.type);
  for (const checked of [law, rendered]) {
    const evidence = roundtrip.evidence.find(e => e.declaration === checked.id && e.stage === 'law');
    assert.equal(evidence?.status, 'exhaustively-checked');
  }
});

test('primitive constructor metadata presents nested records and retains undefined unselected law computations', async () => {
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  const content = `unit display.primitives
function optionalValue (unused of type ()) -> Maybe record{value of type Integer} is Just record{value = 1} end function
function eitherValue (unused of type ()) -> Either record{value of type Integer} Bool is Left record{value = 1} end function
law optional is definition: optionalValue () must be Just record{value = 1} end end
law either is definition: eitherValue () must be Left record{value = 1} end end
law lists is definition: [record{value = 1}, record{value = 2}] must be [record{value = 1}, record{value = 2}] end end
law unused is definition: record{chosen = 1, unused = 1 / 0} must be record{chosen = 1, unused = 1 / 0} end end
`;
  const result = await compiler.check({schemaVersion: 5, languageProfile: '1.0-rc.1', verification: {layers: []},
    sources: [{path: 'primitives.lawspec', content}]});
  assert.deepEqual(result.diagnostics, []);
  const texts = new Map(result.laws.map(law => [law.id.split('::').at(-1), explainLaw(law, result, 'business').text]));
  assert.equal(texts.get('optional'), 'optionalValue () must be Just(value = record{value = 1})');
  assert.equal(texts.get('either'), 'eitherValue () must be Left(value = record{value = 1})');
  assert.match(texts.get('lists'), /\[record\{value = 1\}, record\{value = 2\}\]/);
  assert.equal(texts.get('unused').match(/\(1 \/ 0\)/g)?.length, 2);
  for (const [name, text] of texts) {
    assert.doesNotMatch(text, /lawspec::structural|_lawspec|lawspecRecordView/);
    const law = result.laws.find(law => law.id.endsWith('::' + name));
    assert.equal(result.evidence.find(e => e.declaration === law.id && e.stage === 'law')?.status, 'not-verified');
  }
});

test('emitted operational terms retain handlers, call filters and the original evidence', async () => {
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  for (const fixture of ['abilities', 'failures']) {
    const content = await readFile(new URL(`../../examples/specs/${fixture}.lawspec`, import.meta.url), 'utf8') +
      (fixture === 'abilities' ? '\ndefinition handledCheckout (cents :: Int32) :: Bool is handle checkout cents with fakeGateway end end\n' : '');
    // These published examples remain explicit migration-schema inputs.
    const result = await compiler.expand({schemaVersion: 4, sources: [{path: fixture + '.lawspec', content}]});
    assert.deepEqual(result.diagnostics, []);
    const before = structuredClone(result), render = presentation(result), terms = [];
    function collect(value) {
      if (value === null || typeof value !== 'object') return;
      if (value.type && typeof value.text === 'string' && value.node?.kind) terms.push(value);
      for (const child of Object.values(value)) collect(child);
    }
    collect(result);
    for (const term of terms) {
      const text = render(term), node = term.node;
      assert.equal(typeof text, 'string');
      if (node.kind === 'perform') {
        assert.ok(text.startsWith('perform '));
        assert.ok(text.includes(`.${node.operation}(`));
        if (node.ability.endsWith('::ability::Gateway')) assert.ok(text.startsWith('perform Gateway.'));
      }
      if (node.kind === 'handle' && node.handling === 'catchFailure') assert.ok(text.startsWith('catch failure of '));
      if (node.kind === 'handle' && node.handling === 'withHandler') {
        assert.ok(text.includes(`with ${node.handler} for `));
        if (node.ability.endsWith('::ability::Gateway')) assert.ok(text.endsWith('for Gateway'));
      }
      if (node.kind === 'calls') assert.equal(text.includes(' with ('), node.arguments !== null);
    }
    for (const law of result.laws) for (const view of ['developer', 'business', 'formal', 'evidence']) {
      const shown = explainLaw(law, result, view);
      assert.equal(shown.assertion, law.assertion);
      assert.equal(shown.inputs, law.inputs);
      assert.deepEqual(shown.evidence, result.evidence.filter(e => e.declaration === law.id));
    }
    assert.deepEqual(result, before);
  }
});


test('source provenance names specializations once and qualifies independent declarations', () => {
  const data = {units: [{id: 'use', declarations: [
    {id: 'use::specialized_1', name: 'generated_1', source: {unit: 'library', name: 'echo'}},
    {id: 'use::specialized_2', name: 'generated_2', source: {unit: 'library', name: 'echo'}},
  ]}]};
  const render = presentation(data);
  assert.equal(render(expression({kind: 'call', declaration: 'use::specialized_1', arguments: [number(1)]})), 'echo 1');
  assert.equal(render(expression({kind: 'call', declaration: 'use::specialized_2', arguments: [number(2)]})), 'echo 2');
  const qualified = presentation({units: [...data.units, {id: 'other', declarations: [
    {id: 'other::echo', name: 'echo', source: {unit: 'other', name: 'echo'}},
  ]}]});
  assert.equal(qualified(expression({kind: 'call', declaration: 'use::specialized_1', arguments: [number(1)]})), 'library.echo 1');
});

test('list presentation preserves strict computations and keeps unknown tails explicit', () => {
  const listType = {kind: 'constructor', name: 'List', arguments: [{kind: 'type', type: integer}]};
  const nil = expression({kind: 'construct', constructor: 'List::Nil', arguments: []}, 'Nil', listType);
  const cons = (head, tail) => expression({kind: 'construct', constructor: 'List::Cons', arguments: [head, tail]}, 'Cons', listType);
  const render = presentation({});
  assert.equal(render(cons(binary('/', number(1), number(0)), cons(number(2), nil))), '[(1 / 0), 2]');
  const unknown = expression({kind: 'helper', name: 'unknownTail', arguments: []}, 'tail', listType);
  assert.equal(render(cons(number(1), unknown)), 'Cons(head = 1, tail = unknownTail)');
});

test('checked collection names come only from explicit declaration metadata', () => {
  const listType = {kind: 'constructor', name: 'List', arguments: [{kind: 'type', type: integer}]};
  const list = expression({kind: 'construct', constructor: 'List::Cons', arguments: [number(1),
    expression({kind: 'construct', constructor: 'List::Nil', arguments: []}, 'Nil', listType)]}, 'Cons', listType);
  const data = {units: [{id: 'use', declarations: [
    {id: 'use::trusted', name: 'mangled', source: {unit: 'lawspec.collections', name: 'eqSetOf', canonicalName: 'prelude.setOf'}},
    {id: 'use::fake', name: 'lawspec_lawspecCollectionsEqSetOf_123',
      origin: {kind: 'source', span: {start: {file: '<lawspec.collections>', line: 1, column: 1}}}},
  ]}]};
  const render = presentation(data);
  assert.equal(render(expression({kind: 'call', declaration: 'use::trusted', arguments: [list]})), '#S{1}');
  assert.equal(render(expression({kind: 'call', declaration: 'use::fake', arguments: [list]})), 'lawspec_lawspecCollectionsEqSetOf_123 [1]');
  const opaque = expression({kind: 'helper', name: 'buildItems', arguments: []}, 'buildItems', listType);
  assert.equal(render(expression({kind: 'call', declaration: 'use::trusted', arguments: [opaque]})), 'prelude.setOf (buildItems)');
});

test('membership presentation keeps strict values once and retains dependent bindings', () => {
  const listType = {kind: 'constructor', name: 'List', arguments: [{kind: 'type', type: integer}]};
  const bool = {kind: 'constructor', name: 'Bool', arguments: []};
  const item = binder('item'), needle = binder('needle'), stored = {...binder('stored', 'collection'), type: listType};
  const list = expression({kind: 'construct', constructor: 'List::Cons', arguments: [number(1),
    expression({kind: 'construct', constructor: 'List::Nil', arguments: []}, 'Nil', listType)]}, 'items', listType);
  const value = expression({kind: 'local', id: stored.id}, 'collection', listType);
  const differs = expression({kind: 'binary', operator: '!=', left: local(needle.id), right: local(item.id)}, 'differs', bool);
  const iteration = expression({kind: 'allElements', value, binder: item, predicate: differs}, 'every', bool);
  const found = expression({kind: 'unary', operator: '!', argument: iteration}, 'found', bool);
  const term = letIn(needle, call('first', unit), letIn(stored, list, found));
  const render = presentation({units: functions(['first', 'make'])});
  const before = structuredClone(term);
  assert.equal(render(term), '((first ()) in [1])');
  assert.deepEqual(term, before);
  const dependent = letIn(needle, call('first', unit), letIn(stored, call('make', local(needle.id)), found));
  assert.match(render(dependent), /^let needle = first \(\) in let collection = make needle in /);
});

test('finite existential iteration keeps callback scopes and Boolean polarity', () => {
  const listType = {kind: 'constructor', name: 'List', arguments: [{kind: 'type', type: integer}]};
  const bool = {kind: 'constructor', name: 'Bool', arguments: []};
  const bound = binder('inner', '~lawspecAnyItem');
  const predicate = expression({kind: 'binary', operator: '>', left: local(bound.id), right: local('outside', 'value')}, 'predicate', bool);
  const inverted = expression({kind: 'unary', operator: '!', argument: predicate}, 'not predicate', bool);
  const items = expression({kind: 'construct', constructor: 'List::Nil', arguments: []}, 'Nil', listType);
  const every = expression({kind: 'allElements', value: items, binder: bound, predicate: inverted}, 'every', bool);
  const term = expression({kind: 'unary', operator: '!', argument: every}, 'not every', bool);
  assert.equal(presentation({})(term), 'any value1 in ([]) satisfies ((value1 > value))');
});

test('stored set values use set notation without repairing arbitrary storage expressions', () => {
  const listType = {kind: 'constructor', name: 'List', arguments: [{kind: 'type', type: integer}]};
  const setType = {kind: 'constructor', name: 'lawspec.collections::type::EqSet', arguments: [{kind: 'type', type: integer}]};
  const constructor = setType.name + '::EqSetItems';
  const result = {dataTypes: [{id: setType.name, name: 'Set', parameters: [], constructors: [
    {id: constructor, name: 'EqSetItems', fields: [{...binder('items'), type: listType}]},
  ]}]};
  const one = {type: 'Integer', value: '1'};
  const nil = {kind: 'data', type: listType, constructor: 'List::Nil', fields: []};
  const items = {kind: 'data', type: listType, constructor: 'List::Cons', fields: [one, nil]};
  const before = structuredClone(result);
  assert.equal(createTypePresentation(result).valueText({kind: 'data', type: setType, constructor, fields: [items]}), '#S{1}');
  const rawList = expression({kind: 'construct', constructor: 'List::Cons', arguments: [number(1),
    expression({kind: 'construct', constructor: 'List::Cons', arguments: [number(1),
      expression({kind: 'construct', constructor: 'List::Nil', arguments: []}, 'Nil', listType)]}, 'Cons', listType)]}, 'Cons', listType);
  assert.equal(presentation(result)(expression({kind: 'construct', constructor, arguments: [rawList]}, 'storage', setType)), 'EqSetItems(items = [1, 1])');
  assert.deepEqual(result, before);
});

test('compiled declarations retain authored ownership through facades and polymorphic specialization', async () => {
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  const sources = [
    {path: 'spelling.lawspec', content: 'unit spelling\nfunction same (value :: a) -> a is value end function'},
    {path: 'facade.lawspec', content: 'unit facade\nimport spelling as original\nexport original.same'},
    {path: 'use.lawspec', content: 'unit use\nimport facade as copied\nlaw values is definition: copied.same true = true and copied.same 1 = 1 end end'},
  ];
  const result = await compiler.check({schemaVersion: 5, languageProfile: '1.0-rc.1', verification: {layers: []}, sources});
  assert.deepEqual(result.diagnostics, []);
  const declarations = result.units.flatMap(unit => unit.declarations).filter(d => d.source?.unit === 'spelling');
  assert.equal(new Set(declarations.map(d => d.id)).size, 2);
  for (const declaration of declarations) {
    assert.deepEqual(declaration.source, {unit: 'spelling', name: 'same'});
    assert.notEqual(declaration.name, 'same');
  }
  const law = result.laws.find(law => law.id === 'use::law::values');
  assert.ok(law);
  for (const view of ['developer', 'business', 'formal']) {
    const shown = explainLaw(law, result, view);
    assert.match(shown.text, /same true/);
    assert.match(shown.text, /same 1/);
    assert.doesNotMatch(shown.text, /lawspec_|copied\.|facade\./);
    assert.equal(shown.assertion, law.assertion);
  }
});

test('compiler-looking source paths and names never receive builtin collection presentation', async () => {
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  const name = 'lawspec_lawspecCollectionsEqSetOf_123';
  const content = `unit lookalike
function ${name} (items :: List Bool) -> Set Bool is #S{false} end function
law actual is definition: ${name} [true] = #S{false} end end`;
  const result = await compiler.check({schemaVersion: 5, languageProfile: '1.0-rc.1', verification: {layers: ['exhaustive']},
    sources: [{path: '<lawspec.collections>', content}]});
  assert.deepEqual(result.diagnostics, []);
  const declaration = result.units.flatMap(unit => unit.declarations).find(d => d.name === name);
  assert.deepEqual(declaration?.source, {unit: 'lookalike', name});
  const law = result.laws.find(law => law.id === 'lookalike::law::actual');
  assert.ok(law);
  assert.equal(explainLaw(law, result, 'business').text, `${name} [true] must be #S{false}`);
});

test('compiled source names preserve escaped phrase spelling, case and qualified collisions', async () => {
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  const phrase = String.raw`"|Keep\|Case\\Name|`;
  const sources = [
    {path: 'one.lawspec', content: `unit one\nfunction ${phrase} (value :: a) -> a is value end function`},
    {path: 'two.lawspec', content: `unit two\nfunction ${phrase} (value :: a) -> a is value end function`},
    {path: 'use.lawspec', content: `unit use\nimport one as first\nimport two as second\nlaw names is definition: first.${phrase} true = second.${phrase} true end end`},
  ];
  const result = await compiler.check({schemaVersion: 5, languageProfile: '1.0-rc.1', verification: {layers: []}, sources});
  assert.deepEqual(result.diagnostics, []);
  for (const owner of ['one', 'two']) assert.ok(result.units.flatMap(unit => unit.declarations)
    .some(declaration => declaration.source?.unit === owner && declaration.source.name === phrase));
  const law = result.laws.find(law => law.id === 'use::law::names');
  assert.ok(law);
  assert.equal(explainLaw(law, result, 'business').text, `one.${phrase} true must be two.${phrase} true`);
});

test('set membership explanations recompile with identical typed obligations and finite outcomes', async () => {
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  const content = 'unit readable\nlaw included is definition: true in #S{false, true} end end';
  const request = {schemaVersion: 5, languageProfile: '1.0-rc.1', verification: {layers: ['exhaustive']},
    sources: [{path: 'readable.lawspec', content}]};
  const result = await compiler.check(request);
  assert.deepEqual(result.diagnostics, []);
  const law = result.laws.find(law => law.id === 'readable::law::included');
  assert.ok(law);
  const text = explainLaw(law, result, 'business').text;
  assert.match(text, /true in #S\{false, true\}/);
  assert.doesNotMatch(text, /lawspec_|Cons|EqSetItems/);
  const roundtrip = await compiler.check({...request, sources: [{path: 'readable.lawspec', content:
    content + `\nlaw displayed is definition: ${text} end end`}]});
  assert.deepEqual(roundtrip.diagnostics, []);
  for (const checked of roundtrip.laws) {
    assert.equal(roundtrip.evidence.find(e => e.declaration === checked.id && e.stage === 'law')?.status, 'exhaustively-checked');
    assert.equal(checked.assertion.kind, 'equal');
    assert.deepEqual(checked.assertion.left.type, law.assertion.left.type);
  }
});
