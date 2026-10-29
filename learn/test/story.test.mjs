/** @file Execute every authored scene from its actual files; prose observations must survive these checks. ref:REQ-learn-executable-story */
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile, writeFile} from 'node:fs/promises';
import {course, compile, execute} from './helpers.mjs';
import {buildCourse} from '../build-course.mjs';
import {expectationProblems} from '../browser/story.mjs';
test('the served curriculum and displayed code are generated from the exercise source files', async () =>
{
  assert.deepEqual(await buildCourse(), course);
  for (const lesson of course.lessons)
  {
    for (const stage of [
      ...lesson.stages,
      {
        projects: lesson.solutions,
        sources: lesson.solutionSources,
        id: 'solution',
      },
    ])
    {
      for (const [language, files] of Object.entries(stage.projects))
      {
        for (const [name, content] of Object.entries(files))
        {
          assert.equal(
            content,
            await readFile(
              new URL('../' + stage.sources[language][name], import.meta.url),
              'utf8',
            ),
            `${lesson.id}/${stage.id}/${language}/${name}`,
          );
        }
      }
    }
  }
});
for (const language of ['fsharp', 'typescript', 'javascript'])
{
  test(`${language}: every story scene compiles and exhibits its stated passing or failing observations`, async t =>
  {
    const receipts = [];
    for (const lesson of course.lessons)
    {
      for (const stage of lesson.stages)
      {
        await t.test(`${lesson.id}/${stage.id}`, async () =>
        {
          const plan = await compile(
            lesson,
            language,
            stage.projects[language],
            stage.run.mode,
          );
          assert.deepEqual(
            plan.diagnostics.filter(row => row.severity === 'error'),
            [],
            JSON.stringify(plan.diagnostics),
          );
          assert.ok(plan.code);
          const result = await execute(plan.code);
          receipts.push({
            lesson: lesson.id,
            scene: stage.id,
            mode: result.mode,
            ok: result.ok,
            tests: result.tests,
            property: result.sampled
              ? {
                  status: result.sampled.status,
                  counterexample: result.sampled.counterexample,
                  seed: result.sampled.seed,
                  path: result.sampled.path,
                  numShrinks: result.sampled.numShrinks,
                }
              : null,
          });
          assert.deepEqual(
            expectationProblems(result, stage.run),
            [],
            JSON.stringify({
              ok: result.ok,
              tests: result.tests,
              sampled: result.sampled
                ? {
                    status: result.sampled.status,
                    counterexample: result.sampled.counterexample,
                    error: result.sampled.error,
                  }
                : null,
            }),
          );
        });
      }
    }
    await writeFile(
      new URL(
        `../../.artifacts/learn-preview/story-${language}.json`,
        import.meta.url,
      ),
      JSON.stringify(receipts, null, 2) + '\n',
    );
  });
}
