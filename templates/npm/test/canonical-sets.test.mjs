import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';
import {explanations,explanationText} from './compiler-input.mjs';

const compiler = await createCompiler();
const request = (content, layers = [], machineBits = 64) => ({
  schemaVersion: 5, languageProfile: '1.0-rc.2', machineBits,
  verification: {layers}, sources: [{path: 'sets.lawspec', content}],
});
const evidence = result => result.evidence.filter(item => item.stage === 'law');
const definition = body => `unit set_capabilities\n${body}
end unit
`;

test('canonical membership needs equality without requiring a portable order', async () => {
  const content = await readFile(new URL('../../test/fixtures/canonical-sets.lawspec', import.meta.url), 'utf8');
  for (const bits of [32, 64]) {
    const result = await compiler.check(request(content, ['exhaustive'], bits));
    assert.deepEqual(result.diagnostics, []);
    assert.equal(result.laws.length, 6);
    assert.ok(evidence(result).every(item => item.status === 'exhaustively-checked'));
    assert.ok(evidence(result).every(item => /evaluated all 2 inputs/.test(item.reason)));
    const bare = await compiler.check(request(content, [], bits));
    assert.deepEqual(bare.diagnostics, []);
    assert.ok(evidence(bare).every(item => item.status === 'not-verified'));
    assert.deepEqual(bare.laws.map(law => law.assertion), result.laws.map(law => law.assertion));
  }
});

test('set literal examples stay concrete and unbounded coverage stays incomplete', async () => {
  const content = await readFile(new URL('../../test/fixtures/canonical-set-literals.lawspec', import.meta.url), 'utf8');
  for (const bits of [32, 64]) {
    const input = request(content, ['examples'], bits);
    const result = await compiler.check(input);
    assert.deepEqual(result.diagnostics, []);
    assert.equal(result.laws.length, 6);
    const examples = result.laws.flatMap(law => law.examples);
    assert.equal(examples.length, 11);
    assert.ok(examples.some(example => example.name.includes('#S{')));
    assert.ok(examples.every(example => !example.name.includes('setOf')));
    assert.ok(evidence(result).every(item => item.status === 'planned'));
    const generated = await compiler.planGeneration({...input, target: 'javascript'});
    assert.deepEqual(generated.diagnostics, []);
    const incomplete = await compiler.planGeneration({...input, target: 'javascript', verification: {layers: ['exhaustive', 'examples']}});
    assert.ok(incomplete.diagnostics.some(item => item.code === 'verification-incomplete'));
    const formatted = await compiler.format(input);
    assert.deepEqual(formatted.diagnostics, []);
    const repeated = await compiler.format({...input, sources: formatted.formattedSources});
    assert.deepEqual(repeated.formattedSources, formatted.formattedSources);
  }
});

test('membership and construction require Eq while iteration does not', async () => {
  const bodies = [
    [`function includes (value :: a) (members :: Set a) -> Bool is prelude.member value members end function
`, false],
    [`function includes (value :: a) (members :: Set a) -> Bool requires Eq a is prelude.member value members end function
`, true],
    [`function create (items :: List a) -> Set a is prelude.setOf items end function
`, false],
    [`function create (items :: List a) -> Set a requires Eq a is prelude.setOf items end function
`, true],
    [`function read (members :: Set (a -> a)) -> List (a -> a) is prelude.toList members end function
`, true],
    [`function keep (items :: List Integer) (value :: Int64) -> Int64 is value end function
function negative (unused :: Bool) -> Int64 is keep [] (0 - prelude.Int64 1) end function
`, true],
    [`function invalid (unused :: Bool) -> Set Nat is #S{0} end function
`, false],
    [`function invalid (value :: Integer) -> Set Float64 is #S{value} end function
`, false],
    [`function invalid (unused :: Bool) -> SortedSet Float64 is prelude.sortedSetOf [1.0] end function
`, false],
  ];
  for (const [body, valid] of bodies) {
    const result = await compiler.check(request(definition(body)));
    assert.equal(result.diagnostics.length === 0, valid, `${body}: ${JSON.stringify(result.diagnostics)}`);
    if (valid) assert.equal(result.verification.intrinsicDefinitionChecks, true);
  }
});

test('user paths cannot choose a legacy grammar or compiler-owned identity', async () => {
  const old = `unit user
definition same (value :: Bool) :: Bool is value end
`;
  for (const path of ['user.lawspec', '<user>', '<lawspec.collections>']) {
    const result = await compiler.check({...request(old), sources: [{path, content: old}]});
    assert.ok(result.diagnostics.length > 0, path);
  }
  const source = `unit lawspec.collections

function same (value :: Bool) -> Bool is value end function

end unit
`;
  const result = await compiler.check(request(source));
  assert.ok(result.diagnostics.some(item => item.code === 'reserved-unit'));
});


test('explanation domains use canonical Set and SortedSet metadata', async () => {
  const names = request(`unit set_names

law members is definition: for all (members :: Set Float64) => members = members end for all end definition end law
law ordered is definition: for all (members :: SortedSet Integer) => members = members end for all end definition end law

end unit
`);
  const result = await compiler.check(names);
  assert.deepEqual(result.diagnostics, []);
  const [members, ordered] = (await explanations(compiler, names, 'dev')).map(explanationText);
  assert.match(members, /members of type Set Float64/);
  assert.match(ordered, /members of type SortedSet Integer/);
  assert.ok(evidence(result).every(item => item.status === 'not-verified'));
  const custom = {path: 'custom.lawspec', content: `unit custom

type Set is a record{value :: Bool} end type

end unit
`};
  const use = {path: 'use.lawspec', content: `unit display
import custom as custom
import lawspec.collections as collections
law own is definition: for all (members :: custom.Set) => members = members end for all end definition end law
law builtin is definition: for all (members :: collections.Set Bool) => members = members end for all end definition end law
end unit`};
  const both = {...request(''), sources: [custom, use]};
  const qualified = await compiler.check(both);
  assert.deepEqual(qualified.diagnostics, []);
  const shown = await explanations(compiler, both, 'dev');
  const own = explanationText(shown.find(e => e.law === 'display::law::own'));
  const builtin = explanationText(shown.find(e => e.law === 'display::law::builtin'));
  assert.match(own, /members of type custom\.Set/);
  assert.match(builtin, /members of type lawspec\.collections\.Set Bool/);
  assert.match(explanationText((await explanations(compiler, both, 'eng', 'display::own'))[0]), /For every members \(a custom\.Set\)/);
});
