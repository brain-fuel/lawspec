import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';
import {explanations,explanationText,explanationViews} from './compiler-input.mjs';

const content = await readFile(new URL('../../test/fixtures/canonical-collection-membership.lawspec', import.meta.url), 'utf8');
const input = (machineBits, layers, source = content) => ({schemaVersion: 5, languageProfile: '1.0-rc.2',
  machineBits, verification: {layers}, sources: [{path: 'membership.lawspec', content: source}]});
const evidence = result => result.evidence.filter(item => item.stage === 'law');

test('finite collection membership and predicates share checked typed execution', async () => {
  const compiler = await createCompiler();
  for (const bits of [32, 64]) {
    const request = input(bits, ['exhaustive', 'examples']);
    const result = await compiler.check(request);
    assert.deepEqual(result.diagnostics, []);
    assert.equal(result.laws.length, 20);
    assert.equal(result.laws.flatMap(law => law.examples).length, 6);
    assert.ok(evidence(result).every(item => item.status === 'exhaustively-checked'));
    const bare = await compiler.check(input(bits, []));
    assert.deepEqual(bare.diagnostics, []);
    assert.ok(evidence(bare).every(item => item.status === 'not-verified'));
    assert.deepEqual(bare.laws.map(law => law.assertion), result.laws.map(law => law.assertion));
    for (const view of explanationViews) for (const shown of await explanations(compiler, request, view)) {
      assert.ok(result.laws.some(law => law.id === shown.law));
      assert.doesNotMatch(explanationText(shown), /~lawspecAnyItem/);
      assert.doesNotMatch(explanationText(shown), /lawspec_[\w]+_[\da-f]{8,}|EqSetItems|Cons\(head/);
    }
    const formatted = await compiler.format(request);
    assert.deepEqual(formatted.diagnostics, []);
    const repeated = await compiler.format({...request, sources: formatted.formattedSources});
    assert.deepEqual(repeated.formattedSources, formatted.formattedSources);
  }
});

test('membership keeps Eq, mandatory strict argument checks and explicit map selection', async () => {
  const compiler = await createCompiler();
  const cases = [
    [`function includes (value :: a) (members :: List a) -> Bool is value in members end function
`, false],
    [`function includes (value :: a) (members :: List a) -> Bool requires Eq a is value in members end function
`, true],
    [`function selected (value :: a) -> Bool is true end function
function scan (members :: Queue a) -> Bool is prelude.any selected members end function
`, true],
    [`function invalid (ignored :: Bool) -> Bool is (1 / 0) in ([] :: List Integer) end function
`, false],
    [`function exceeds (limit :: Integer) (value :: Integer) -> Bool is value > limit end function
function invalid (ignored :: Bool) -> Bool is prelude.any (exceeds (1 / 0)) ([] :: List Integer) end function
`, false],
    [`law invalid is definition: 1 in prelude.keyValOf [Entry 1 2] end definition end law
`, false],
    [`law invalid is definition: "a" in "abc" end definition end law
`, false],
  ];
  for (const [body, valid] of cases) {
    const result = await compiler.check(input(64, [], `unit capability_checks\n${body}
end unit
`));
    assert.equal(result.diagnostics.length === 0, valid, `${body}: ${JSON.stringify(result.diagnostics)}`);
    if (valid) assert.equal(result.verification.intrinsicDefinitionChecks, true);
  }
});

test('independent expectation mutants remain executable native tests', async () => {
  const compiler = await createCompiler();
  for (const bits of [32, 64]) for (const name of ['membership', 'predicate', 'signed-zero']) {
    const mutant = await readFile(new URL(`../../acceptance/rc1-collection-membership/mutants/${name}.mutant`, import.meta.url), 'utf8');
    const [, search, replacement] = mutant.match(/<<<<<<<\n([\s\S]*?)\n=======\n([\s\S]*?)\n>>>>>>>/);
    assert.ok(content.includes(search), name);
    const result = await compiler.planGeneration({...input(bits, ['exhaustive', 'examples'], content.replace(search, replacement)), target: 'javascript'});
    assert.deepEqual(result.diagnostics, [], `${name}: ${JSON.stringify(result.diagnostics)}`);
    assert.ok(result.files.some(file => file.path.endsWith('.test.mjs')));
  }
});
