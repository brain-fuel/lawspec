import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';

const content = await readFile(new URL('../../test/fixtures/canonical-prelude-names.lawspec', import.meta.url), 'utf8');
const request = (machineBits, layers, source = content) => ({schemaVersion: 5, languageProfile: '1.0-rc.1',
  machineBits, verification: {layers}, sources: [{path: 'prelude-names.lawspec', content: source}]});

test('unqualified prelude names keep checked obligations, optional evidence and formatting', async () => {
  const compiler = await createCompiler();
  for (const bits of [32, 64]) {
    const input = request(bits, ['exhaustive', 'examples']);
    const result = await compiler.check(input);
    assert.deepEqual(result.diagnostics, []);
    assert.equal(result.laws.length, 8);
    assert.ok(result.evidence.filter(item => item.stage === 'law').every(item => item.status === 'exhaustively-checked'));
    const bare = await compiler.check(request(bits, []));
    assert.deepEqual(bare.diagnostics, []);
    assert.deepEqual(bare.laws.map(law => law.assertion), result.laws.map(law => law.assertion));
    assert.ok(bare.evidence.filter(item => item.stage === 'law').every(item => item.status === 'not-verified'));
    const formatted = await compiler.format(input);
    assert.deepEqual(formatted.diagnostics, []);
    const repeated = await compiler.format({...input, sources: formatted.formattedSources});
    assert.deepEqual(repeated.formattedSources, formatted.formattedSources);
  }
});

test('prelude fallback preserves scopes, explicit-import ambiguity and mandatory rejection', async () => {
  const compiler = await createCompiler();
  const cases = [
    ['type Regex is one of | OwnRegex end type\ntype Duration is one of | OwnDuration end type\ntype RetryDecision is one of | OwnRetry end type\nlaw separate is definition: sameItems [true] [true] and toMicroseconds (seconds 1) = 1000000 and OwnRegex = OwnRegex and OwnDuration = OwnDuration and OwnRetry = OwnRetry end end', true],
    ['type Duration is one of | Own end type\nfunction invalid (unused :: Bool) -> Duration is seconds 1 end function', false],
    ['function length (value :: Bool) -> Bool is not value end function\nlaw local is definition: length true = false end end', true],
    ['function includes (value :: a) (items :: List a) -> Bool is member value items end function', false],
    ['function includes (value :: a) (items :: List a) -> Bool requires Eq a is member value items end function', true],
    ['function selected (value :: a) -> Bool is true end function\nfunction scan (items :: List a) -> Bool is any selected items end function', true],
    ['function invalid (unused :: Bool) -> Bool is member (1 / 0) ([] :: List Integer) end function', false],
    ['type Choice is one of | Right of type Bool end type\nfunction selected (value :: Bool) -> Bool is value end function\nfunction invalid (value :: Bool) -> Bool is bind (Right value) selected end function', false],
    ['law invalid is definition: incompleteSearch () = true end end', false],
  ];
  for (const [body, valid] of cases) {
    const result = await compiler.check(request(64, [], `unit scopes\n${body}`));
    assert.equal(result.diagnostics.length === 0, valid, JSON.stringify(result.diagnostics));
    if (valid) assert.equal(result.verification.intrinsicDefinitionChecks, true);
  }
  const result = await compiler.check({...request(64, []), sources: [
    ...['first', 'second'].map(name => ({path: name + '.lawspec', content: `unit ${name}\nfunction length (value :: Bool) -> Bool is value end function`})),
    {path: 'use.lawspec', content: 'unit use\nimport first as first (length)\nimport second as second (length)\nlaw ambiguous is definition: length true = true end end'},
  ]});
  assert.ok(result.diagnostics.some(diagnostic => /imported from more than one unit/.test(diagnostic.message)));
});

test('independent prelude expectations remain native tests rather than generation rejections', async () => {
  const compiler = await createCompiler();
  for (const bits of [32, 64]) for (const name of ['predicate', 'count', 'duration']) {
    const mutant = await readFile(new URL(`../../acceptance/rc1-prelude-names/mutants/${name}.mutant`, import.meta.url), 'utf8');
    const [, search, replacement] = mutant.match(/<<<<<<<\n([\s\S]*?)\n=======\n([\s\S]*?)\n>>>>>>>/);
    assert.ok(content.includes(search), name);
    const result = await compiler.planGeneration({...request(bits, ['exhaustive', 'examples'], content.replace(search, replacement)), target: 'javascript'});
    assert.deepEqual(result.diagnostics, [], name);
    assert.ok(result.files.some(file => file.path.endsWith('.test.mjs')));
  }
});
