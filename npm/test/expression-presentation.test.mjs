// Generated from templates/npm/test/expression-presentation.test.mjs by lawspec-dev generate. Do not edit.
import {
  extendUnit,
  explanations,
  explanationText,
  explanationViews,
} from './compiler-input.mjs';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';

// Rendering rules for synthetic checked terms, and for every term of the
// ability and failure examples, are compiler tests: test/ExplainSpec.hs.
const statement = explanation =>
  explanation.sections
    .find(section => section.kind === 'statement')
    .lines.join('\n');

test('actual parcel assertions use readable terms with the original obligations and evidence', async () =>
{
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  const content = await readFile(
    new URL('../../examples/rc1/parcel-measurements.lawspec', import.meta.url),
    'utf8',
  );
  const request = {
    schemaVersion: 5,
    languageProfile: '1.0-rc.2',
    verification: {layers: []},
    sources: [{path: 'parcel-measurements.lawspec', content}],
  };
  const result = await compiler.check(request);
  assert.deepEqual(result.diagnostics, []);
  const law = result.laws.find(law => law.id.endsWith('::sampleWeight'));
  assert.ok(law);
  const shown = {};
  for (const view of explanationViews)
  {
    shown[view] = explanationText(
      (await explanations(compiler, request, view)).find(e => e.law === law.id),
    );
    assert.doesNotMatch(
      shown[view],
      /lawspec::structural|lawspecRecordView|_lawspecRecordField/,
    );
  }
  assert.match(
    shown.dev,
    /sampleParcel \(\) = Parcel\(details = record\{weight = Measurement\(reading = record\{value = 1\}\)\}\)/,
  );
  assert.match(
    shown.math,
    /sampleParcel\(\(\)\) = Parcel\(details = record\{weight = Measurement\(reading = record\{value = 1\}\)\}\)/,
  );
  assert.match(
    shown.eng,
    /The sample parcel must be a parcel with details \(a record with weight \(a measurement with reading \(a record with value 1\)\)\)\./,
  );
  assert.deepEqual((await compiler.check(request)).evidence, result.evidence);
});

test('rendered structural assertions recompile with the same checked outcome and source field order', async () =>
{
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  const content = `unit display.order

function first (unused of type ()) -> Integer is 1 end function
function second (unused of type ()) -> Integer is 2 end function
law ordered is
  definition:
    record{z = first (), a = second ()} must be record{a = 2, z = 1}
  end definition
end law

end unit
`;
  const request = {
    schemaVersion: 5,
    languageProfile: '1.0-rc.2',
    verification: {layers: ['exhaustive']},
    sources: [{path: 'order.lawspec', content}],
  };
  const result = await compiler.check(request);
  assert.deepEqual(result.diagnostics, []);
  const law = result.laws.find(law => law.id.endsWith('::ordered'));
  assert.ok(law);
  const text = statement(
    (await explanations(compiler, request, 'dev', 'display.order::ordered'))[0],
  );
  assert.equal(
    text,
    'record{z = first (), a = second ()} = record{a = 2, z = 1}',
  );
  const roundtrip = await compiler.check({
    ...request,
    sources: [
      {
        path: 'order.lawspec',
        content: extendUnit(
          content,
          `\nlaw displayed is definition: ${text} end definition end law
`,
        ),
      },
    ],
  });
  assert.deepEqual(roundtrip.diagnostics, []);
  const rendered = roundtrip.laws.find(law => law.id.endsWith('::displayed'));
  assert.ok(rendered);
  assert.deepEqual(rendered.assertion.left.type, law.assertion.left.type);
  for (const checked of [law, rendered])
  {
    const evidence = roundtrip.evidence.find(
      e => e.declaration === checked.id && e.stage === 'law',
    );
    assert.equal(evidence?.status, 'exhaustively-checked');
  }
});

test('primitive constructor metadata presents nested records and retains undefined unselected law computations', async () =>
{
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  const content = `unit display.primitives

function optionalValue (unused of type ()) -> Maybe record{value of type Integer} is Present record{value = 1} end function
function eitherValue (unused of type ()) -> Either record{value of type Integer} Bool is Left record{value = 1} end function
law optional is definition: optionalValue () must be Present record{value = 1} end definition end law
law either is definition: eitherValue () must be Left record{value = 1} end definition end law
law lists is definition: [record{value = 1}, record{value = 2}] must be [record{value = 1}, record{value = 2}] end definition end law
law unused is definition: record{chosen = 1, unused = 1 / 0} must be record{chosen = 1, unused = 1 / 0} end definition end law

end unit
`;
  const request = {
    schemaVersion: 5,
    languageProfile: '1.0-rc.2',
    verification: {layers: []},
    sources: [{path: 'primitives.lawspec', content}],
  };
  const result = await compiler.check(request);
  assert.deepEqual(result.diagnostics, []);
  const texts = new Map(
    (await explanations(compiler, request, 'dev')).map(e => [
      e.law.split('::').at(-1),
      statement(e),
    ]),
  );
  assert.equal(
    texts.get('optional'),
    'optionalValue () = Present(value = record{value = 1})',
  );
  assert.equal(
    texts.get('either'),
    'eitherValue () = Left(value = record{value = 1})',
  );
  assert.match(
    texts.get('lists'),
    /\[record\{value = 1\}, record\{value = 2\}\]/,
  );
  assert.equal(texts.get('unused').match(/1 \/ 0/g)?.length, 2);
  for (const [name, text] of texts)
  {
    assert.doesNotMatch(text, /lawspec::structural|_lawspec|lawspecRecordView/);
    const law = result.laws.find(law => law.id.endsWith('::' + name));
    assert.equal(
      result.evidence.find(e => e.declaration === law.id && e.stage === 'law')
        ?.status,
      'not-verified',
    );
  }
});

test('compiled declarations retain authored ownership through facades and polymorphic specialization', async () =>
{
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  const sources = [
    {
      path: 'spelling.lawspec',
      content: `unit spelling

function same (value :: a) -> a is value end function

end unit
`,
    },
    {
      path: 'facade.lawspec',
      content: `unit facade
import spelling as original
export original.same
end unit
`,
    },
    {
      path: 'use.lawspec',
      content: `unit use
import facade as copied
law values is definition: copied.same true = true and copied.same 1 = 1 end definition end law
end unit
`,
    },
  ];
  const request = {
    schemaVersion: 5,
    languageProfile: '1.0-rc.2',
    verification: {layers: []},
    sources,
  };
  const result = await compiler.check(request);
  assert.deepEqual(result.diagnostics, []);
  const declarations = result.units
    .flatMap(unit => unit.declarations)
    .filter(d => d.source?.unit === 'spelling');
  assert.equal(new Set(declarations.map(d => d.id)).size, 2);
  for (const declaration of declarations)
  {
    assert.deepEqual(declaration.source, {unit: 'spelling', name: 'same'});
    assert.notEqual(declaration.name, 'same');
  }
  const law = result.laws.find(law => law.id === 'use::law::values');
  assert.ok(law);
  const spelled = {
    dev: [/same true/, /same 1/],
    math: [/same\(true\)/, /same\(1\)/],
    eng: [/the same for true must be true/, /the same for 1 must be 1/],
  };
  for (const view of explanationViews)
  {
    const shown = explanationText(
      (await explanations(compiler, request, view, 'use::values'))[0],
    );
    for (const pattern of spelled[view]) assert.match(shown, pattern);
    assert.doesNotMatch(shown, /lawspec_|copied\.|facade\./);
  }
});

test('compiler-looking source paths and names never receive builtin collection presentation', async () =>
{
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  const name = 'lawspec_lawspecCollectionsEqSetOf_123';
  const content = `unit lookalike

function ${name} (items :: List Bool) -> Set Bool is #S{false} end function
law actual is definition: ${name} [true] = #S{false} end definition end law

end unit
`;
  const request = {
    schemaVersion: 5,
    languageProfile: '1.0-rc.2',
    verification: {layers: ['exhaustive']},
    sources: [{path: '<lawspec.collections>', content}],
  };
  const result = await compiler.check(request);
  assert.deepEqual(result.diagnostics, []);
  const declaration = result.units
    .flatMap(unit => unit.declarations)
    .find(d => d.name === name);
  assert.deepEqual(declaration?.source, {unit: 'lookalike', name});
  const law = result.laws.find(law => law.id === 'lookalike::law::actual');
  assert.ok(law);
  assert.equal(
    statement(
      (await explanations(compiler, request, 'dev', 'lookalike::actual'))[0],
    ),
    `${name} [true] = #S{false}`,
  );
});

test('compiled source names preserve escaped phrase spelling, case and qualified collisions', async () =>
{
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  const phrase = String.raw`"|Keep\|Case\\Name|`;
  const sources = [
    {
      path: 'one.lawspec',
      content: `unit one

function ${phrase} (value :: a) -> a is value end function

end unit
`,
    },
    {
      path: 'two.lawspec',
      content: `unit two

function ${phrase} (value :: a) -> a is value end function

end unit
`,
    },
    {
      path: 'use.lawspec',
      content: `unit use\nimport one as first\nimport two as second\nlaw names is definition: first.${phrase} true = second.${phrase} true end definition end law
end unit
`,
    },
  ];
  const request = {
    schemaVersion: 5,
    languageProfile: '1.0-rc.2',
    verification: {layers: []},
    sources,
  };
  const result = await compiler.check(request);
  assert.deepEqual(result.diagnostics, []);
  for (const owner of ['one', 'two'])
    assert.ok(
      result.units
        .flatMap(unit => unit.declarations)
        .some(
          declaration =>
            declaration.source?.unit === owner &&
            declaration.source.name === phrase,
        ),
    );
  const law = result.laws.find(law => law.id === 'use::law::names');
  assert.ok(law);
  assert.equal(
    statement((await explanations(compiler, request, 'dev', 'use::names'))[0]),
    `one.${phrase} true = two.${phrase} true`,
  );
});

test('set membership explanations recompile with identical typed obligations and finite outcomes', async () =>
{
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  const content = `unit readable

law included is definition: true in #S{false, true} end definition end law

end unit
`;
  const request = {
    schemaVersion: 5,
    languageProfile: '1.0-rc.2',
    verification: {layers: ['exhaustive']},
    sources: [{path: 'readable.lawspec', content}],
  };
  const result = await compiler.check(request);
  assert.deepEqual(result.diagnostics, []);
  const law = result.laws.find(law => law.id === 'readable::law::included');
  assert.ok(law);
  const text = statement(
    (await explanations(compiler, request, 'dev', 'readable::included'))[0],
  );
  assert.match(text, /true in #S\{false, true\}/);
  assert.doesNotMatch(text, /lawspec_|Cons|EqSetItems/);
  const roundtrip = await compiler.check({
    ...request,
    sources: [
      {
        path: 'readable.lawspec',
        content: extendUnit(
          content,
          `\nlaw displayed is definition: ${text} end definition end law
`,
        ),
      },
    ],
  });
  assert.deepEqual(roundtrip.diagnostics, []);
  for (const checked of roundtrip.laws)
  {
    assert.equal(
      roundtrip.evidence.find(
        e => e.declaration === checked.id && e.stage === 'law',
      )?.status,
      'exhaustively-checked',
    );
    assert.equal(checked.assertion.kind, 'equal');
    assert.deepEqual(checked.assertion.left.type, law.assertion.left.type);
  }
});
