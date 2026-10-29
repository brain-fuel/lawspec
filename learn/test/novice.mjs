import assert from 'node:assert/strict';
import {course} from './helpers.mjs';

/** Follow the first-use naming, results and recovery path with actual typing and execution. ref:REQ-learn-english-names ref:REQ-learn-novice-results */
export async function verifyNoviceExperience(browser, base)
{
  const context = await browser.newContext({
    viewport: {width: 1440, height: 1000},
  });
  try
  {
    const page = await context.newPage();
    const visit = async (lesson, stage, language = 'fsharp') =>
    {
      await page.goto(
        base +
          '#' +
          new URLSearchParams({
            course: course.version,
            lesson: lesson.id,
            scene: stage.id,
            language,
            track: 'shared',
          }),
      );
      await page.reload();
      await page.waitForFunction(
        () => document.documentElement.dataset.ready === 'true',
      );
    };
    const read = () =>
      page.evaluate(async () =>
      {
        const {monaco} = await import('./vendor/editor.mjs');
        return monaco.editor.getModels()[0].getValue();
      });
    const run = async () =>
    {
      await page.locator('#run').click();
      await page.waitForFunction(
        () => document.querySelector('#cancel').disabled,
        null,
        {timeout: 120000},
      );
      return page.locator('#result-status').innerText();
    };
    const addition = course.lessons[0];
    await visit(addition, addition.stages[0]);
    await page.getByRole('tab', {name: 'Laws', exact: true}).click();
    await page.evaluate(async () =>
    {
      const {monaco} = await import('./vendor/editor.mjs');
      const model = monaco.editor.getModels()[0],
        editor = monaco.editor.getEditors()[0];
      const name = '"|one plus two is three|',
        offset = model.getValue().indexOf(name);
      if (offset < 0) throw new Error('Missing phrase-name example');
      const start = model.getPositionAt(offset),
        end = model.getPositionAt(offset + name.length);
      model.pushEditOperations(
        [],
        [
          {
            range: new monaco.Range(
              start.lineNumber,
              start.column,
              end.lineNumber,
              end.column,
            ),
            text: '',
          },
        ],
        () => [],
      );
      editor.setPosition(start);
      editor.focus();
    });
    await page.keyboard.type('"|my first promise|');
    assert.match(await read(), /law "\|my first promise\| is/);
    assert.doesNotMatch(await read(), /my first promise\|"/);
    assert.equal(await run(), 'Checks passed');
    assert.match(
      await page.locator('#outcomes').innerText(),
      /my first promise/,
    );
    assert.match(await page.locator('#outcomes').innerText(), /add 1 2 → 3/);
    await page.locator('#stage [data-stage="1"]').click();
    await page.waitForFunction(() =>
      location.hash.includes('scene=second-promise'),
    );
    assert.equal(await run(), 'Check the failure');
    assert.match(
      await page.locator('#teaching-feedback').innerText(),
      /meant to reveal a failing check/,
    );
    assert.match(
      await page.locator('#outcomes').innerText(),
      /two plus two is four/,
    );
    assert.match(await page.locator('#outcomes').innerText(), /add 2 2 → 0/);
    assert.doesNotMatch(
      await page.locator('#outcomes').innerText(),
      /boundary 1|learn\.addition::/,
    );
    await page.locator('#stage [data-stage="4"]').click();
    await page.waitForFunction(() => location.hash.includes('scene=multiply'));
    assert.equal(await run(), 'Checks passed');
    assert.match(
      await page.locator('#message').innerText(),
      /1 sampled property · 100 generated trials/,
    );
    const threshold = course.lessons.find(row => row.id === 'wlaschin-shrink');
    await visit(threshold, threshold.stages[1]);
    assert.equal(await run(), 'Check the failure');
    assert.match(
      await page.locator('#outcomes').innerText(),
      /Failing input after shrinking/,
    );
    assert.match(await page.locator('#outcomes').innerText(), /80/);
    const trace = page.locator('#outcomes details').filter({
      has: page.getByText('How the failure was reduced', {exact: true}),
    });
    assert.equal(await trace.evaluate(element => element.open), false);
    await trace.locator('summary').click();
    assert.match(await trace.innerText(), /replayPath/);
    // Seed previous supplied projects to verify that the real load path updates
    // an untouched pair but preserves a learner's implementation and kept law.
    const stage = addition.stages[0],
      old = stage.previousProjects;
    const kept = old.javascript['Tests.lawspec'].replace(
      /end unit\s*$/,
      'law keptExample is definition: add 2 2 = 4 end definition end law\nend unit\n',
    );
    await page.evaluate(
      async ({version, id, scene, stage, old, kept}) =>
      {
        const {openStore} = await import('./store.mjs');
        const store = await openStore();
        await store.put([version, id, 'shared', 'fsharp', scene].join('/'), {
          files: {
            ...old.fsharp,
            'Solution.fs':
              'module Solution\nlet add (x: int) (y: int) : int = x + y\n',
          },
          stage,
          completed: false,
        });
        await store.put(
          [version, id, 'shared', 'javascript', scene].join('/'),
          {
            files: {...old.javascript, 'Tests.lawspec': kept},
            stage,
            completed: false,
          },
        );
      },
      {
        version: course.version,
        id: addition.id,
        scene: stage.id,
        stage: 0,
        old,
        kept,
      },
    );
    await visit(addition, stage);
    await page.getByRole('tab', {name: 'Laws', exact: true}).click();
    assert.match(await read(), /law "\|one plus two is three\| is/);
    await page.getByRole('tab', {name: 'Solution', exact: true}).click();
    assert.match(await read(), /x \+ y/);
    await visit(addition, stage, 'javascript');
    await page.getByRole('tab', {name: 'Laws', exact: true}).click();
    assert.equal(await read(), kept);
    await page.locator('#load-stage').click();
    await page.getByRole('tab', {name: 'Laws', exact: true}).click();
    assert.doesNotMatch(await read(), /keptExample/);
    await page.locator('#undo-replacement').click();
    assert.equal(await read(), kept);
    assert.equal(await run(), 'Check the failure');
    assert.match(
      await page
        .locator('#outcomes .failed')
        .allTextContents()
        .then(rows => rows.join('\n')),
      /keptExample/,
    );
    await page.locator('#solution').click();
    await page.waitForFunction(() => location.hash.includes('scene=repair'));
    assert.equal(
      await page.locator('#files [aria-selected=true]').innerText(),
      'Solution',
    );
    assert.equal(await run(), 'Checks passed');
    await page.locator('#undo-replacement').click();
    assert.equal(await run(), 'Check the failure');
  }
  finally
  {
    await context.close();
  }
}
