import {extendUnit} from './compiler-input.mjs';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { test } from 'node:test';
import { createTypePresentation } from '../typed-presentation.mjs';
import { explainLaw } from '../explain.mjs';

const type = (name, ...arguments_) => ({ kind: 'constructor', name,
  arguments: arguments_.map(type => ({ kind: 'type', type })) });
const variable = id => ({ kind: 'variable', id });
const integer = type('Integer');
function record(id, fields, parameters = [], predicates = {}) {
  return { id, name: id, parameters, constructors: [{ id: `${id}::Record`, name: 'Record',
    fields: fields.map(([name, type]) => ({ id: `${id}::Record::${name}`, name, type })) }],
  structure: { kind: 'record', fields: fields.map(([name]) => ({ name, predicates: predicates[name] ?? [] })) } };
}
const local = (id, text = id) => ({ text, node: { kind: 'local', id } });
const field = (constructor, index, value) => ({ text: `(${value.text}).${index}`,
  node: { kind: 'field', constructor, index, value } });
const binary = (operator, left, right) => ({ text: `(${left.text} ${operator} ${right.text})`,
  node: { kind: 'binary', operator, left, right } });

test('structural type presentations substitute generic fields and retain nominal boundaries', () => {
  const inner = record('inner', [['value', variable('a')]], ['a']);
  const outer = record('outer', [['items', type('List', type('inner', variable('b')))],
    ['owner', type('shop::type::Customer')]], ['b']);
  const customer = { id: 'shop::type::Customer', parameters: [], constructors: [{ id: 'Customer', name: 'Customer',
    fields: [{ id: 'next', name: 'next', type: type('shop::type::Customer') }] }] };
  const { typeName } = createTypePresentation({ dataTypes: [inner, outer, customer] });
  assert.equal(typeName(type('outer', integer)), 'record{items of type List (record{value of type Integer}), owner of type Customer}');
  assert.equal(typeName(type(customer.id)), 'Customer');
  assert.equal(typeName(type('Either', integer, type('Maybe', type('BigUInt')))), 'Either Integer (Maybe Whole)');
  assert.equal(createTypePresentation({ dataTypes: [record('empty', [])] }).typeName(type('empty')), 'record{}');
});

test('typed Boolean wording preserves IEEE comparisons and literal contents', () => {
  const predicate = { text: 'original predicate', node: { kind: 'shortCircuit', operator: '||',
    left: binary('==', { text: 'NaN' }, { text: 'NaN' }), right: { text: 'original negation',
      node: { kind: 'unary', operator: '!', argument: binary('==', local('flags::Record::text'), { text: '"a == b && c"' }) } } } };
  const flags = record('flags', [['text', type('Text')]], [], { text: [predicate] });
  assert.equal(createTypePresentation({ dataTypes: [flags] }).typeName(type('flags')),
    'record{text of type (text of type Text where ((NaN = NaN) or not ((text = "a == b && c"))))}');
});

test('same-spelled nominal types stay distinct and absent metadata retains its identity', () => {
  const declarations = ['first', 'second'].map(unit => ({ id: `${unit}::type::Item`, parameters: [], constructors: [] }));
  const { typeName } = createTypePresentation({ dataTypes: declarations });
  assert.equal(typeName(type(declarations[0].id)), 'first.Item');
  assert.equal(typeName(type(declarations[1].id)), 'second.Item');
  assert.equal(typeName(type('lawspec::structural::record::unknown')), 'lawspec::structural::record::unknown');
});

test('field restrictions keep dependent labels, every predicate and unfamiliar expressions', () => {
  const left = local('range::Record::lower', 'private-lower'), right = local('range::Record::upper', 'private-upper');
  const range = record('range', [['lower', integer], ['upper', integer]], [], {
    lower: [{ text: 'externalLowerCheck lower', node: { kind: 'future-node' } }],
    upper: [binary('>=', right, left), { text: 'externalUpperCheck upper' }],
  });
  assert.equal(createTypePresentation({ dataTypes: [range] }).typeName(type('range')),
    'record{lower of type (lower of type Integer where externalLowerCheck lower), upper of type (upper of type Integer where (upper >= lower) and externalUpperCheck upper)}');
});

test('presentation removes only generated record views and retains user computations', () => {
  const source = record('source', [['value', integer]]), target = record('target', [['value', integer]]);
  const input = local('subject', 'reading');
  const binder = { id: 'lawspec::record-view::private', name: 'private', type: integer };
  const view = { text: 'original storage view', origin: { kind: 'generated', declaration: 'lawspec::source-record' },
    node: { kind: 'match', value: input, cases: [{ constructor: 'source::Record', binders: [binder],
      body: { node: { kind: 'construct', constructor: 'target::Record', arguments: [local(binder.id)] } } }] } };
  const domain = expression => record('domain', [['reading', type('source')]], [], {
    reading: [binary('>', field('target::Record', 0, expression), { text: '0' })],
  });
  const render = expression => createTypePresentation({ dataTypes: [source, target, domain(expression)] }).typeName(type('domain'));
  assert.match(render(view), /where \(reading.value > 0\)/);
  const userMatch = { ...view, text: 'user match with extra checks', origin: { kind: 'source' } };
  assert.match(render(userMatch), /\(user match with extra checks\)\.value/);
  const reversed = structuredClone(view);
  reversed.node.cases[0].body.node.arguments[0] = { text: '1 / 0', node: { kind: 'future-node' } };
  reversed.text = 'checked construction containing 1 / 0';
  assert.match(render(reversed), /checked construction containing 1 \/ 0/);
  const construct = { text: 'record{value = 1, unused = 1 / 0}', node: { kind: 'construct', constructor: 'target::Record', arguments: [] } };
  assert.match(render(construct), /unused = 1 \/ 0/);
});

test('actual checked parcel domains show field names and refinements without altering obligations or evidence', async () => {
  const { createCompiler } = await import('../api.mjs');
  const compiler = await createCompiler();
  const content = await readFile(new URL('../../examples/rc1/parcel-measurements.lawspec', import.meta.url), 'utf8');
  const result = await compiler.check({ schemaVersion: 5, languageProfile: '1.0-rc.2', verification: { layers: [] },
    sources: [{ path: 'parcel-measurements.lawspec', content }] });
  assert.deepEqual(result.diagnostics, []);
  const law = result.laws.find(law => law.id.endsWith('::positiveWeights'));
  assert.ok(law);
  const before = structuredClone(result);
  for (const view of ['developer', 'business', 'formal']) {
    const explanation = explainLaw(law, result, view);
    assert.match(explanation.text, /parcel of type record\{weight of type \(weight of type Measurement Integer where \(weight\.reading\.value > 0\)\)\}/);
    assert.doesNotMatch(explanation.text, /lawspec::structural|lawspecRecordView/);
    assert.equal(explanation.assertion, law.assertion);
    assert.equal(explanation.inputs, law.inputs);
    assert.deepEqual(explanation.evidence, result.evidence.filter(e => e.declaration === law.id));
  }
  const nested = { ...law, inputs: [], assertion: { kind: 'exists', binder: law.inputs[0], predicates: [], body: law.assertion } };
  assert.match(explainLaw(nested, result, 'business').text, /There must exist parcel of type record\{/);
  assert.match(explainLaw(law, result, 'evidence').text, /NOT-VERIFIED/);
  assert.deepEqual(result, before);
  const displayedType = createTypePresentation(result).typeName(law.inputs[0].type);
  const roundtrip = await compiler.check({ schemaVersion: 5, languageProfile: '1.0-rc.2', verification: { layers: [] },
    sources: [{ path: 'parcel-measurements.lawspec', content: extendUnit(content,
      `\nfunction domainIdentity (value of type ${displayedType}) -> ${displayedType} is\n  value\nend function\n`) }] });
  assert.deepEqual(roundtrip.diagnostics, []);
  const identity = roundtrip.definitions.find(d => d.id.endsWith('::domainIdentity'));
  assert.ok(identity);
  assert.deepEqual(identity.arguments[0].type, law.inputs[0].type);
  assert.deepEqual(identity.body.type, law.inputs[0].type);
  assert.equal(roundtrip.dataTypes.find(d => d.id === identity.arguments[0].type.name).structure.descriptor,
    result.dataTypes.find(d => d.id === law.inputs[0].type.name).structure.descriptor);
});
