import {test} from 'node:test';
import assert from 'node:assert/strict';
import {course, compile, execute, services} from './helpers.mjs';
import {
  describeCheck,
  observedCall,
  runSummary,
} from '../browser/presentation.mjs';
import {refreshProvidedLaws} from '../browser/store.mjs';

test('English claims and a phrase-named helper generate conventional identifiers without changing the sort checks', async () =>
{
  const lesson = course.lessons.find(row => row.id === 'wlaschin-sort');
  const files = lesson.solutions.javascript;
  const sources = Object.entries(files)
    .filter(([path]) => path.endsWith('.lawspec'))
    .map(([path, content]) => ({path, content}));
  const core = await services.lawspec();
  for (const [target, identifier, helper] of [
    [
      'javascript',
      '|sorting orders values and keeps every occurrence|',
      /function isInAscendingOrder\(/,
    ],
    [
      'fsharp',
      'lawSortingOrdersValuesAndKeepsEveryOccurrence',
      /let isInAscendingOrder /,
    ],
    [
      'python',
      'test_sorting_orders_values_and_keeps_every_occurrence',
      /def is_in_ascending_order\(/,
    ],
    [
      'rust',
      'law_sorting_orders_values_and_keeps_every_occurrence',
      /fn is_in_ascending_order\(/,
    ],
  ])
  {
    const plan = await core.planGeneration({
      languageProfile: '1.0-rc.2',
      target,
      verification: {layers: ['property']},
      sources,
    });
    assert.deepEqual(plan.diagnostics, []);
    assert.ok(
      plan.tests.some(row => row.name.includes(identifier)),
      target,
    );
    assert.ok(
      plan.files.some(row => helper.test(row.content)),
      target,
    );
  }
  const plan = await compile(lesson, 'javascript', files);
  assert.equal((await execute(plan.code)).ok, true);
});

test('results explain real calls and distinguish a sampled property from its one hundred input trials', async () =>
{
  const lesson = course.lessons[0];
  const plan = await compile(
    lesson,
    'fsharp',
    lesson.stages[0].projects.fsharp,
    'examples',
  );
  const result = await execute(plan.code);
  assert.equal(result.ok, true);
  assert.deepEqual(result.tests[0].calls, [{input: [1, 2], output: 3}]);
  assert.equal(
    observedCall(plan.binding, result.tests[0].calls[0], 'fsharp'),
    'add 1 2 → 3',
  );
  assert.equal(
    observedCall(plan.binding, result.tests[0].calls[0], 'javascript'),
    'add(1, 2) → 3',
  );
  assert.deepEqual(describeCheck(result.tests[0].name, plan.checks), {
    label: 'one plus two is three',
    kind: 'Specific inputs',
  });
  const sampled = await execute(
    (
      await compile(
        lesson,
        'javascript',
        lesson.stages[4].projects.javascript,
        'sample',
      )
    ).code,
  );
  assert.equal(sampled.properties.length, 1);
  assert.equal(sampled.properties[0].numRuns, 100);
  assert.match(
    runSummary(sampled, 10),
    /1 sampled property · 100 generated trials/,
  );
});

test('starter-law refresh preserves implementation edits and refuses to overwrite kept laws or edited harnesses', async () =>
{
  const lesson = course.lessons[0],
    stage = lesson.stages[0],
    previous = stage.previousProjects.fsharp,
    current = stage.projects.fsharp;
  const files = {
    ...previous,
    'Solution.fs': 'module Solution\nlet add (x: int) (y: int) : int = x + y\n',
  };
  const draft = {files, completed: true};
  assert.equal(refreshProvidedLaws(draft, previous, current), true);
  assert.equal(draft.completed, true);
  assert.equal(draft.files['Solution.fs'], files['Solution.fs']);
  assert.equal(
    (
      await execute(
        (await compile(lesson, 'fsharp', draft.files, 'examples')).code,
      )
    ).ok,
    true,
  );
  const kept = {
    ...previous,
    'Tests.lawspec': previous['Tests.lawspec'].replace(
      /end unit\s*$/,
      'law keptExample is definition: add 2 2 = 4 end definition end law\nend unit\n',
    ),
  };
  const before = structuredClone(kept);
  assert.equal(refreshProvidedLaws({files: kept}, previous, current), false);
  assert.deepEqual(kept, before);
  const result = await execute(
    (await compile(lesson, 'fsharp', kept, 'examples')).code,
  );
  assert.ok(
    result.tests.some(row => row.name.includes('keptExample') && !row.ok),
  );
  const harnessEdit = {
    ...previous,
    'Harness.lawspec': previous['Harness.lawspec'] + '\n-- learner choice\n',
  };
  assert.equal(
    refreshProvidedLaws({files: harnessEdit}, previous, current),
    false,
  );
  assert.equal(harnessEdit['Tests.lawspec'], previous['Tests.lawspec']);
});
