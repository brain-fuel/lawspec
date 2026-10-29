// Generated from templates/npm/test/business-demonstrations.test.mjs by lawspec-dev generate. Do not edit.
import {
  semanticFacts,
  explanations,
  explanationViews,
} from './compiler-input.mjs';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {test} from 'node:test';
import {createCompiler} from '../api.mjs';
import {programTargets as targets} from '../templates.mjs';

const compiler = await createCompiler();
const canonical = {schemaVersion: 5, languageProfile: '1.0-rc.2'};
const source = async name => ({
  path: `examples/rc1/${name}.lawspec`,
  content: await readFile(
    new URL(`../examples/rc1/${name}.lawspec`, import.meta.url),
    'utf8',
  ),
});

test('refund and stateful order examples retain their obligations, exact amounts and independent outcomes', async () =>
{
  const sources = await Promise.all(
    ['refund-policy', 'refund-conformance', 'order-workflow'].map(source),
  );
  for (const machineBits of [32, 64])
  {
    const input = {
      ...canonical,
      machineBits,
      sources,
      verification: {layers: []},
    };
    const result = await compiler.check(input);
    assert.deepEqual(result.diagnostics, []);
    assert.equal(result.laws.length, 8);
    assert.equal(result.laws.flatMap(law => law.examples).length, 40);
    assert.ok(
      result.evidence
        .filter(item => item.stage === 'law')
        .every(item => item.status === 'not-verified'),
    );
    const formatted = await compiler.format(input);
    assert.deepEqual(formatted.diagnostics, []);
    const again = await compiler.format({
      ...input,
      sources: formatted.formattedSources,
    });
    assert.deepEqual(again.formattedSources, formatted.formattedSources);
    const original = await compiler.check({...input});
    const checked = await compiler.check({
      ...input,
      sources: formatted.formattedSources,
    });
    assert.deepEqual(checked.diagnostics, []);
    assert.deepEqual(semanticFacts(checked), semanticFacts(original));
    const examples = await compiler.planGeneration({
      ...input,
      target: 'javascript',
      verification: {layers: ['examples']},
    });
    assert.deepEqual(examples.diagnostics, []);
    assert.equal(examples.tests.length, 4);
    assert.equal(
      examples.tests.reduce((sum, entry) => sum + entry.coverage.cases, 0),
      40,
    );
    for (const view of explanationViews)
    {
      const shown = await explanations(compiler, input, view);
      assert.deepEqual(
        shown.map(e => e.law),
        result.laws.map(law => law.id),
      );
      assert.ok(shown.every(e => e.view === view));
    }
    assert.deepEqual((await compiler.check(input)).evidence, result.evidence);
    const invalid = await compiler.check({
      ...input,
      sources: [
        ...sources,
        {
          path: 'invalid.lawspec',
          content: `unit invalid

function invalidPolicy (value :: Integer) -> Integer is prelude.quot value 0 end function

end unit
`,
        },
      ],
    });
    assert.ok(invalid.diagnostics.some(item => item.code === 'total'));
  }
});

test('every target emits refund and stateful order checks at both widths and layouts', async () =>
{
  const sources = await Promise.all(
    ['refund-policy', 'refund-conformance', 'order-workflow'].map(source),
  );
  for (const machineBits of [32, 64])
    for (const minify of [false, true])
      for (const target of targets)
      {
        const result = await compiler.planGeneration({
          ...canonical,
          sources,
          machineBits,
          minify,
          target,
          verification: {layers: ['property', 'examples']},
        });
        assert.deepEqual(
          result.diagnostics,
          [],
          `${target}:${machineBits}:${minify}`,
        );
        assert.equal(result.tests.length, 8);
        assert.ok(result.files.length);
        assert.ok(
          result.evidence
            .filter(item => item.stage === 'law')
            .every(item => item.status === 'planned'),
        );
      }
});

test('conflicting requirements produce concrete refutations for either proposed policy without implying joint solver analysis', async () =>
{
  const original = await source('conflicting-requirements');
  for (const machineBits of [32, 64])
  {
    const input = {
      ...canonical,
      machineBits,
      sources: [original],
      verification: {layers: []},
    };
    const unselected = await compiler.check(input);
    assert.deepEqual(unselected.diagnostics, []);
    assert.equal(unselected.laws.length, 2);
    assert.ok(
      unselected.evidence
        .filter(item => item.stage === 'law')
        .every(item => item.status === 'not-verified'),
    );
    const selected = await compiler.check({
      ...input,
      verification: {layers: ['exhaustive']},
    });
    assert.deepEqual(
      selected.diagnostics.map(item => item.code),
      ['refuted'],
    );
    assert.match(
      selected.diagnostics[0].message,
      /every request is approved.*flagged = true/,
    );
    const alwaysApproved = {
      ...original,
      content: original.content.replace(
        'if flagged then ReviewRequired else Approved end if',
        'Approved',
      ),
    };
    assert.notEqual(alwaysApproved.content, original.content);
    const revised = await compiler.check({
      ...input,
      sources: [alwaysApproved],
      verification: {layers: ['exhaustive']},
    });
    assert.deepEqual(
      revised.diagnostics.map(item => item.code),
      ['refuted'],
    );
    assert.match(
      revised.diagnostics[0].message,
      /a flagged request requires review/,
    );
  }
});
