/** @file Check the course contract with actual execution and negative controls. ref:REQ-learn-local-execution ref:REQ-learn-progress-portability ref:REQ-learn-generated-boundaries */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {course, compile, execute, services} from './helpers.mjs';
import {bundle} from '../browser/bundle.mjs';
import {adapterSource} from '../browser/adapters.mjs';
import {validateImport, draftKey} from '../browser/store.mjs';
const seat = course.lessons.find(row => row.id === 'examples');
const sorting = course.lessons.find(row => row.id === 'wlaschin-sort');
const temperatures = course.lessons.find(row => row.id === 'shrinking');
for (const language of ['fsharp', 'typescript', 'javascript'])
{
  test(`${language}: all three solutions execute the real generated contracts`, async () =>
  {
    for (const lesson of course.lessons)
    {
      const plan = await compile(lesson, language, lesson.solutions[language]);
      assert.deepEqual(
        plan.diagnostics.filter(row => row.severity === 'error'),
        [],
        JSON.stringify(plan.diagnostics),
      );
      assert.ok(plan.code);
      const result = await execute(plan.code);
      assert.equal(result.ok, true, JSON.stringify(result));
      assert.ok(result.tests.some(row => row.name.includes('::')));
      assert.ok(result.properties.length > 0);
      assert.ok(
        result.properties.some(row => row.origin.includes('LawSpec property')),
      );
      assert.match(result.sampled.origin, /LawSpec property/);
      assert.equal(plan.definitionValidation.intrinsicDefinitionChecks, true);
      assert.ok(plan.evidence.some(row => row.status === 'planned')); // Planning stays planning.
    }
  });
}
test('a memorized implementation passes its authored examples but fails an unfamiliar row', async () =>
{
  const lesson = seat;
  const examples = await execute(
    (await compile(lesson, 'fsharp', {}, 'examples')).code,
  );
  assert.equal(examples.ok, true);
  const bad = await execute(
    (await compile(lesson, 'fsharp', lesson.stages[2].projects.fsharp)).code,
  );
  assert.equal(bad.ok, false);
  assert.equal(bad.sampled.status, 'failed');
  const newlyFailing = await execute(
    (
      await compile(
        lesson,
        'fsharp',
        lesson.stages[1].projects.fsharp,
        'examples',
      )
    ).code,
  );
  assert.equal(newlyFailing.ok, false);
});
test('ordering accepts empty output; preservation rejects empty, lost duplicates and substitutions', async () =>
{
  const lesson = sorting;
  const weak = await execute((await compile(lesson)).code);
  assert.equal(weak.ok, true);
  const strong = lesson.stages[1].projects.fsharp;
  for (const implementation of [
    '[]',
    'List.distinct xs |> List.sort',
    'List.map (fun _ -> 0) xs',
  ])
  {
    const result = await execute(
      (
        await compile(lesson, 'fsharp', {
          ...strong,
          'Solution.fs': `module Solution\nlet sort (xs: int list) : int list = ${implementation}\n`,
        })
      ).code,
    );
    assert.equal(result.ok, false, implementation);
    assert.ok(result.properties.some(row => row.status === 'failed'));
  }
});
test('an alternate correct solution is accepted without matching the supplied solution text', async () =>
{
  const l = sorting;
  const result = await execute(
    (
      await compile(l, 'fsharp', {
        ...l.solutions.fsharp,
        'Solution.fs':
          'module Solution\nlet sort (xs: int list) : int list = List.sortBy (fun x -> x) xs\n',
      })
    ).code,
  );
  assert.equal(result.ok, true);
});
test('the temperature summary accepts a different order while still rejecting lost zero and repeated values', async () =>
{
  const files = temperatures.solutions.javascript;
  for (const [body, expected] of [
    ['return [...new Set(xs)].reverse();', true],
    ['return [...new Set(xs)].filter(x => x !== 0);', false],
    ['return xs;', false],
  ])
  {
    const plan = await compile(temperatures, 'javascript', {
      ...files,
      'Solution.js': `export function unique(xs)\n{\n  ${body}\n}\n`,
    });
    assert.deepEqual(
      plan.diagnostics.filter(row => row.severity === 'error'),
      [],
    );
    assert.ok(plan.code);
    const result = await execute(plan.code);
    assert.equal(result.ok, expected, body);
  }
});
test('widening the LawSpec strategy produces actual shrinking, replay and a failing saved regression', async () =>
{
  const lesson = temperatures;
  const blind = await execute(
    (await compile(lesson, 'fsharp', {}, 'sample')).code,
  );
  assert.equal(blind.ok, true);
  assert.equal(blind.coverage.zero, 0);
  const files = lesson.stages[1].projects.fsharp;
  const failed = await execute(
    (await compile(lesson, 'fsharp', files, 'sample')).code,
  );
  assert.deepEqual(failed.sampled.counterexample, [[0]]);
  assert.ok(failed.sampled.numShrinks > 0);
  assert.equal(failed.sampled.counterexampleDomain, 'law-inputs');
  const replay = await execute(
    (
      await compile(
        lesson,
        'fsharp',
        files,
        'sample',
        failed.sampled.path,
        failed.sampled.test,
      )
    ).code,
  );
  assert.deepEqual(
    replay.sampled.counterexample,
    failed.sampled.counterexample,
  );
  assert.equal(
    (
      await execute(
        (
          await compile(
            lesson,
            'fsharp',
            lesson.stages[2].projects.fsharp,
            'examples',
          )
        ).code,
      )
    ).ok,
    false,
  );
  assert.equal(
    (
      await execute(
        (await compile(lesson, 'fsharp', lesson.solutions.fsharp)).code,
      )
    ).ok,
    true,
  );
});
test('incorrect F# and TypeScript types are diagnostics with no executable output', async () =>
{
  for (const [language, name, source] of [
    [
      'fsharp',
      'Solution.fs',
      'module Solution\nlet seats (rows: int) : int = "four"\n',
    ],
    [
      'typescript',
      'Solution.ts',
      'export function seats(rows: number): number { return "four"; }',
    ],
  ])
  {
    const plan = await compile(seat, language, {
      ...seat.stages[2].projects[language],
      [name]: source,
    });
    assert.equal(plan.code, undefined);
    assert.ok(plan.diagnostics.some(row => row.severity === 'error'));
  }
});
test('definition validation is mandatory even when only authored examples are selected', async () =>
{
  const source =
    'unit learn.seats\nfunction broken (n :: Int32) -> Int32 is "wrong" end function\nend unit';
  const plan = await compile(
    seat,
    'javascript',
    {'Tests.lawspec': source},
    'examples',
  );
  assert.equal(plan.code, undefined);
  assert.ok(plan.diagnostics.length > 0);
});
test('missing LawSpec checks are visible and a vacuous property cannot conceal failing concrete claims', async () =>
{
  const files = {...seat.stages[2].projects.javascript};
  const noTests = await compile(seat, 'javascript', {
    ...files,
    'Tests.lawspec': 'unit learn.seats\nseats :: Int32 -> Int32\nend unit\n',
    'Harness.lawspec':
      'harness learn.seats.testing for learn.seats is end harness\n',
  });
  await assert.rejects(execute(noTests.code), /Missing LawSpec checks/);
  const original = files['Tests.lawspec'];
  files['Tests.lawspec'] = original.replace(
    /seats rows = rows\s*\*\s*4/,
    'true',
  );
  assert.notEqual(
    files['Tests.lawspec'],
    original,
    'the negative control must actually replace the property',
  );
  const result = await execute((await compile(seat, 'javascript', files)).code);
  assert.equal(result.sampled.status, 'passed');
  assert.equal(result.ok, false);
  assert.ok(
    result.tests.some(
      row => row.name.includes('three rows have twelve seats') && !row.ok,
    ),
  );
});
test('integer and list adapters round-trip bounds and reject malformed values', async () =>
{
  for (const shape of ['integer', 'list'])
  {
    const modules = {
      'Solution.js': 'export const echo=x=>x;',
      'lesson-adapter.js': adapterSource(
        {name: 'echo', input: shape, output: shape},
        'javascript',
      ),
      'entry.mjs': `import {call} from './lesson-adapter.js';const values=${shape === 'integer' ? '[-2147483648,0,2147483647]' : '[[],[-2147483648,0,0,2147483647]]'};let rejected=false;try{call(${shape === 'integer' ? '1.5' : '["bad"]'});}catch{rejected=true;}postMessage({result:{values:values.map(call),rejected}});`,
    };
    const result = await execute(
      await bundle(services.esbuild, modules, 'entry.mjs', services.readAsset),
    );
    assert.equal(result.rejected, true);
    assert.deepEqual(
      result.values,
      shape === 'integer'
        ? [-2147483648, 0, 2147483647]
        : [[], [-2147483648, 0, 0, 2147483647]],
    );
  }
});
test('esbuild resolves real imports, re-exports and cycles and refuses outside modules', async () =>
{
  const modules = {
    'entry.mjs': `import {answer} from './a.js';postMessage({result:{answer}});`,
    'a.js': `export {answer} from './b.js';export const unused=0;`,
    'b.js': `import {unused} from './a.js';export const answer=42;`,
  };
  assert.equal(
    (
      await execute(
        await bundle(
          services.esbuild,
          modules,
          'entry.mjs',
          services.readAsset,
        ),
      )
    ).answer,
    42,
  );
  await assert.rejects(
    bundle(
      services.esbuild,
      {'entry.mjs': `import 'https://example.com/upload';`},
      'entry.mjs',
      services.readAsset,
    ),
    /Unsupported import/,
  );
});
test('unsupported native imports and infinite implementations remain visible', async () =>
{
  await assert.rejects(
    compile(
      seat,
      'javascript',
      {
        'Solution.js':
          "import {writeFileSync} from 'node:fs';export const seats=rows=>rows*4;",
      },
      'examples',
    ),
    /Unsupported native import/,
  );
  const plan = await compile(
    seat,
    'javascript',
    {'Solution.js': 'export function seats(rows){while(true){}}'},
    'examples',
  );
  await assert.rejects(execute(plan.code, 200), /timed out/);
});
test('imports validate all drafts before writing and never carry execution receipts', () =>
{
  const value = {files: seat.projects.fsharp, stage: 0, completed: false};
  const project = {
    format: 'lawspec-learn',
    version: course.version,
    drafts: [
      {
        key: draftKey('examples', 'booking', 'fsharp', seat.stages[0].id),
        value,
      },
    ],
  };
  assert.doesNotThrow(() => validateImport(project, course));
  assert.throws(
    () => validateImport({...project, version: 'future'}, course),
    /Unsupported/,
  );
  assert.throws(
    () =>
      validateImport(
        {
          ...project,
          drafts: [
            ...project.drafts,
            {key: `${course.version}/examples/shared/rust/familiar`, value},
          ],
        },
        course,
      ),
    /identity/,
  );
});
test('Fable integer/list bridges round-trip the supported shapes before using the JS harness', async () =>
{
  for (const [shape, body, inputs] of [
    ['integer', 'let call (x: int) : int = x', [-2147483648, 0, 2147483647]],
    [
      'list',
      'let call (xs: int array) : int array = xs |> Array.toList |> List.toArray',
      [[], [-2147483648, 0, 0, 2147483647]],
    ],
  ])
  {
    const result = await services.fsharp({
      'Bridge.fs': 'module Bridge\n' + body + '\n',
    });
    assert.deepEqual(result.diagnostics, []);
    const modules = {
      ...result.modules,
      'entry.mjs': `import {call} from './Bridge.js';postMessage({result:{values:${JSON.stringify(inputs)}.map(call)}});`,
    };
    const observed = await execute(
      await bundle(services.esbuild, modules, 'entry.mjs', services.readAsset),
    );
    assert.deepEqual(observed.values, inputs, shape);
  }
});
test('adapters, generated files and bundles repeat byte for byte for the same checked project and pins', async () =>
{
  const {createHash} = await import('node:crypto');
  const hash = text => createHash('sha256').update(text).digest('hex');
  for (const lesson of course.lessons)
  {
    for (const language of ['fsharp', 'typescript', 'javascript'])
    {
      const first = await compile(lesson, language, lesson.solutions[language]);
      const second = await compile(
        lesson,
        language,
        lesson.solutions[language],
      );
      assert.ok(first.code, JSON.stringify(first.diagnostics));
      assert.ok(second.code, JSON.stringify(second.diagnostics));
      assert.deepEqual(second.binding, first.binding);
      const ordered = files =>
        [...files].sort((a, b) => a.path.localeCompare(b.path));
      assert.equal(
        hash(JSON.stringify(ordered(second.generated))),
        hash(JSON.stringify(ordered(first.generated))),
        lesson.id + '/' + language + ' generated files',
      );
      assert.equal(
        hash(second.code),
        hash(first.code),
        lesson.id + '/' + language + ' bundle',
      );
    }
  }
});
test('checked unit, function and value shapes drive wiring independently of lesson identifiers', async () =>
{
  const original = seat;
  const renamed = {...original, id: 'not-a-known-lesson'};
  for (const language of ['fsharp', 'typescript', 'javascript'])
  {
    const files = {
      ...original.projects[language],
      ...original.solutions[language],
    };
    for (const name of Object.keys(files))
    {
      files[name] = files[name]
        .replaceAll('learn.seats', 'hall.layout')
        .replaceAll('seats', 'capacity');
    }
    const plan = await compile(renamed, language, files);
    assert.ok(plan.code, JSON.stringify(plan.diagnostics));
    assert.equal(plan.binding.declaration, 'hall.layout::capacity');
    assert.equal(plan.binding.unit, 'hall.layout');
    assert.ok(
      plan.generated.some(row => row.path === 'adapter/src/hall/layout.mjs'),
    );
    assert.equal((await execute(plan.code)).ok, true);
  }
});
test('checked signatures may have different supported input and result shapes', async () =>
{
  const files = {
    'Tests.lawspec':
      'unit review.counting\ncount :: List Int32 -> Int32\nlaw empty is definition: count [] = 0 end definition end law\nend unit\n',
    'Harness.lawspec':
      'harness review.counting.testing for review.counting is end harness\n',
    'Solution.fs':
      'module Solution\nlet count (xs: int list) : int = List.length xs\n',
  };
  const plan = await compile(seat, 'fsharp', files);
  assert.ok(plan.code, JSON.stringify(plan.diagnostics));
  assert.equal(plan.binding.input, 'list');
  assert.equal(plan.binding.output, 'integer');
  assert.equal((await execute(plan.code)).ok, true);
});
test('unsupported admitted signatures remain explicit instead of receiving a guessed adapter', async () =>
{
  const plan = await compile(seat, 'fsharp', {
    'Tests.lawspec':
      'unit review.unsupported\necho :: Text -> Text\nend unit\n',
    'Harness.lawspec':
      'harness review.unsupported.testing for review.unsupported is end harness\n',
  });
  assert.equal(plan.code, undefined);
  assert.equal(plan.definitionValidation.intrinsicDefinitionChecks, true);
  assert.ok(
    plan.diagnostics.some(
      row =>
        row.code === 'LEARN_UNSUPPORTED_BINDING' &&
        row.message.includes('Unsupported browser adapter type'),
    ),
  );
});
test('every active project has only implementation code and LawSpec tests/strategies', () =>
{
  for (const lesson of course.lessons)
  {
    for (const stage of lesson.stages)
    {
      for (const [language, files] of Object.entries(stage.projects))
      {
        assert.deepEqual(Object.keys(files), [
          'Solution.' +
            {fsharp: 'fs', typescript: 'ts', javascript: 'js'}[language],
          'Tests.lawspec',
          'Harness.lawspec',
        ]);
      }
    }
  }
});
test('a false threshold claim shrinks to 80, replays, and accepts the corrected claim without changing the classifier', async () =>
{
  const lesson = course.lessons.find(row => row.id === 'wlaschin-shrink'),
    stage = lesson.stages[1];
  const failed = await execute(
    (await compile(lesson, 'fsharp', stage.projects.fsharp, 'sample')).code,
  );
  assert.deepEqual(failed.sampled.counterexample, [80]);
  assert.ok(failed.sampled.numShrinks > 0);
  const replay = await execute(
    (
      await compile(
        lesson,
        'fsharp',
        stage.projects.fsharp,
        'sample',
        failed.sampled.path,
        failed.sampled.test,
      )
    ).code,
  );
  assert.deepEqual(replay.sampled.counterexample, [80]);
  assert.equal(
    stage.projects.fsharp['Solution.fs'],
    lesson.solutions.fsharp['Solution.fs'],
  );
  assert.equal(
    (
      await execute(
        (await compile(lesson, 'fsharp', lesson.solutions.fsharp)).code,
      )
    ).ok,
    true,
  );
  const wrong = {
    ...lesson.solutions.fsharp,
    'Solution.fs': lesson.solutions.fsharp['Solution.fs'].replace(
      'n < 80',
      'n <= 80',
    ),
  };
  const mutant = await execute((await compile(lesson, 'fsharp', wrong)).code);
  assert.equal(mutant.ok, false);
  assert.ok(
    mutant.tests.some(
      row => row.name.includes('eighty is not below eighty') && !row.ok,
    ),
  );
});
