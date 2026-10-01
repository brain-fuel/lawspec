// Generated from templates/npm/test/structures.test.mjs by lawspec-dev generate. Do not edit.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';

const compiler = await createCompiler();
const bundled = async name => [{
  path: `${name}.lawspec`,
  content: await readFile(new URL(`../examples/specs/${name}.lawspec`, import.meta.url), 'utf8'),
}];
const shape = value => value.kind === 'data'
  ? [value.constructor, ...value.fields.map(shape)]
  : value;

test('WASM preserves nested sum tags, surrogate units and octets in structural examples', async () => {
  const sources = await bundled('lists');
  for (const machineBits of [32, 64]) {
    const result = await compiler.check({sources, machineBits});
    assert.deepEqual(result.diagnostics, []);
    const maybe = result.laws.find(law => law.name === 'Maybe preserves nested absence');
    assert.deepEqual(maybe.examples.map(example => shape(example.bindings[0].value)), [
      ['Maybe::Nothing'],
      ['Maybe::Just', ['Maybe::Nothing']],
      ['Maybe::Just', ['Maybe::Just', {type: 'Bool', value: true}]],
    ]);
    const raw = result.laws.find(law => law.name === 'nested raw values survive');
    assert.deepEqual(shape(raw.examples[0].bindings[0].value),
      ['List::Cons', ['Maybe::Nothing'],
        ['List::Cons', ['Maybe::Just', ['Either::Left', {type: 'CodeUnit16', value: 55296}]],
          ['List::Cons', ['Maybe::Just', ['Either::Right', {type: 'Bytes', units: [0, 255]}]],
            ['List::Nil']]]]);
  }
});

test('WASM exports named product fields and recursive sum constructors', async () => {
  const result = await compiler.check({sources: await bundled('data_types')});
  assert.deepEqual(result.diagnostics, []);
  const pair = result.dataTypes.find(type => type.name === 'Pair');
  const tree = result.dataTypes.find(type => type.name === 'Tree');
  assert.equal(pair.parameters.length, 2);
  assert.deepEqual(pair.constructors[0].fields.map(field => field.name), ['first', 'second']);
  assert.deepEqual(tree.constructors.map(constructor => constructor.name), ['Leaf', 'Branch']);
  const children = tree.constructors[1].fields[0].type;
  assert.equal(children.name, 'List');
  assert.equal(children.arguments[0].type.name, tree.id);
  assert.deepEqual(shape(result.laws[0].examples[0].bindings[0].value),
    [pair.constructors[0].id, {type: 'Int8', value: '127'}, {type: 'Bool', value: false}]);
});
