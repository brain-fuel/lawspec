// Generated from templates/npm/test/case-fold-checks.mjs by lawspec-dev generate. Do not edit.
// The pinned Unicode folding checks at one machine width. Each width is a
// test file of its own, so the two run at once and are cached apart.
import assert from 'node:assert/strict';
import {createCompiler} from '../api.mjs';
import {explanations, explanationText} from './compiler-input.mjs';
import {programTargets as targets} from '../templates.mjs';

export async function foldingChecks(machineBits)
{
  const compiler = await createCompiler();
  const sources = [
    {
      path: 'folding.lawspec',
      content: `unit folding

function caseFold (text of type Text) -> Text is text end function
function folded (text of type Text) -> Text is prelude.caseFold text end function
law local is definition: caseFold "A" must be "A" end definition end law
law portable is definition: prelude.caseFold "Straße Σς ﬃ İ I 𐐀" must be "strasse σσ ffi i̇ i 𐐨" end definition end law
law substring is definition: prelude.any (prelude.textContains "xSHITx") ["SHIT"] end definition end law

end unit
`,
    },
  ];
  const input = {
    schemaVersion: 5,
    languageProfile: '1.0-rc.2',
    machineBits,
    verification: {layers: ['exhaustive']},
    sources,
  };
  const result = await compiler.check(input);
  assert.deepEqual(result.diagnostics, []);
  assert.ok(
    result.evidence
      .filter(item => item.stage === 'law')
      .every(item => item.status === 'exhaustively-checked'),
  );
  const law = result.laws.find(law => law.name === 'portable');
  assert.ok(law);
  for (const view of ['eng', 'math', 'dev'])
  {
    const [shown] = await explanations(
      compiler,
      input,
      view,
      'folding::portable',
    );
    // eng names prelude functions by their words; math and dev keep the name.
    assert.match(
      explanationText(shown),
      view === 'eng' ? /The case fold for/ : /prelude\.caseFold/,
    );
    assert.doesNotMatch(
      explanationText(shown),
      /textFoldPoint|lawspecTextTextCaseFold/,
    );
  }
  const none = await compiler.check({...input, verification: {layers: []}});
  assert.deepEqual(none.diagnostics, []);
  assert.ok(
    none.evidence
      .filter(item => item.stage === 'law')
      .every(item => item.status === 'not-verified'),
  );
  const invalid = await compiler.check({
    ...input,
    verification: {layers: []},
    sources: [
      {
        path: 'bad.lawspec',
        content: `unit bad

function bad (value :: Integer) -> Text is prelude.caseFold value end function

end unit
`,
      },
    ],
  });
  assert.ok(
    invalid.diagnostics.length > 0,
    'Optional layers cannot disable type checking',
  );
  const forbidden = await compiler.check({
    ...input,
    sources: [
      {
        path: 'owned.lawspec',
        content: `unit lawspec.text


end unit
`,
      },
    ],
  });
  assert.ok(forbidden.diagnostics.some(item => item.code === 'reserved-unit'));
  for (const target of targets)
  {
    const generation = await compiler.planGeneration({
      ...input,
      target,
      minify: machineBits === 32,
    });
    assert.deepEqual(generation.diagnostics, [], `${target}/${machineBits}`);
    assert.ok(generation.files.length > 0);
  }
}
