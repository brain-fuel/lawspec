/** @file Check the actual course hierarchy and secondary controls. ref:REQ-learn-course-hierarchy */
import assert from 'node:assert/strict';
import {readFile, writeFile} from 'node:fs/promises';
/** Verify scope, navigation and reduced toolbar height without changing learner drafts. ref:REQ-learn-course-hierarchy */
export async function verifyCourseNavigation(page, course, output, name)
{
  assert.deepEqual(await page.locator('#lessons h3').allTextContents(), [
    'Worked examples',
    'Practice',
  ]);
  assert.deepEqual(
    await page
      .locator('#lessons [data-lesson]')
      .evaluateAll(rows => rows.map(row => row.dataset.lesson)),
    course.lessons.map(row => row.id),
  );
  assert.equal(await page.locator('#stage').count(), 1);
  assert.equal(await page.locator('.lesson-reader [data-stage]').count(), 0);
  assert.equal(
    await page.locator('#stage [data-stage]').count(),
    course.lessons[0].stages.length,
  );
  assert.equal(
    await page
      .locator('#lessons [data-lesson="wlaschin-add"]+ol#stage')
      .count(),
    1,
  );
  assert.equal(await page.locator('#tracks').count(), 0);
  assert.doesNotMatch(
    await page.locator('header').textContent(),
    /Teaching preview|Planned|Export|Import/i,
  );
  assert.equal(
    await page.locator('#progress-panel').evaluate(element => element.open),
    false,
  );
  await page.locator('#progress-panel>summary').click();
  assert.equal(await page.locator('#export').innerText(), 'Back up progress');
  assert.equal(await page.locator('#restore').innerText(), 'Restore progress');
  assert.match(
    await page.locator('#backup-help').innerText(),
    /all saved lessons, steps, languages and notebooks/,
  );
  assert.match(
    await page.locator('#restore-help').innerText(),
    /Matching drafts are replaced; other drafts stay/,
  );
  await page.locator('#progress-panel>summary').click();
  await page.locator('#about-course>summary').click();
  assert.match(
    await page.locator('#course-status').innerText(),
    /teaching preview/i,
  );
  assert.equal(await page.locator('#planned-tracks').isVisible(), false);
  await page.locator('#roadmap-panel>summary').click();
  assert.deepEqual(
    await page.locator('#planned-tracks li b').allTextContents(),
    ['Event booking', 'Library lending', 'Orders and refunds'],
  );
  assert.equal(
    await page.locator('#planned-tracks button,#planned-tracks a').count(),
    0,
  );
  assert.equal(
    await page.locator('#future-attribution a').count(),
    course.futureAttribution.length,
  );
  await page.locator('#roadmap-panel>summary').click();
  await page.locator('#about-course>summary').click();
  await page.locator('#lessons [data-lesson="wlaschin-sort"]').click();
  await page.waitForFunction(() =>
    location.hash.includes('lesson=wlaschin-sort'),
  );
  assert.equal(
    await page.locator('#stage [data-stage]').count(),
    course.lessons[1].stages.length,
  );
  assert.equal(
    await page
      .locator('#lessons [data-lesson="wlaschin-sort"]+ol#stage')
      .count(),
    1,
  );
  await page.locator('#stage [data-stage="1"]').click();
  await page.waitForFunction(() => location.hash.includes('scene=preserve'));
  assert.equal(
    await page.locator('#stage [aria-current=step]').textContent(),
    '2' + course.lessons[1].stages[1].title,
  );
  assert.equal(
    await page.locator('#stage-title').textContent(),
    course.lessons[1].stages[1].title,
  );
  await page.locator('#lessons [data-lesson="wlaschin-add"]').click();
  await page.waitForFunction(() =>
    location.hash.includes('lesson=wlaschin-add'),
  );
  await page.getByRole('tab', {name: 'F#', exact: true}).focus();
  await page.keyboard.press('ArrowRight');
  await page.waitForFunction(() =>
    location.hash.includes('language=typescript'),
  );
  assert.equal(
    await page
      .getByRole('tab', {name: 'TypeScript', exact: true})
      .getAttribute('aria-selected'),
    'true',
  );
  await page.keyboard.press('ArrowLeft');
  await page.waitForFunction(() => location.hash.includes('language=fsharp'));
  const before = JSON.parse(
      await readFile(new URL('ui-before.json', output)).catch(() => '[]'),
    ),
    receipts = [];
  for (const [width, height] of [
    [1440, 900],
    [1280, 720],
    [390, 844],
    [1366, 600],
  ])
  {
    await page.setViewportSize({width, height});
    if (width < 1100 || height < 720)
    {
      await page.locator('[data-view=code]').click();
    }
    await page.waitForFunction(() =>
    {
      const editor = document.querySelector('.monaco-editor');
      return (
        editor &&
        Math.abs(
          editor.getBoundingClientRect().width -
            document.querySelector('#editor').getBoundingClientRect().width,
        ) < 2
      );
    });
    const value = await page.evaluate(() =>
    {
      const rect = selector =>
      {
        const {top, bottom, height} = document
          .querySelector(selector)
          .getBoundingClientRect();
        return {top, bottom, height};
      };
      return {
        width: innerWidth,
        height: innerHeight,
        header: rect('header'),
        toolbar: {height: rect('#editor').top - rect('.workspace').top},
        editor: rect('#editor'),
        results: rect('.results'),
        run: rect('#run'),
        overflow: document.documentElement.scrollWidth > innerWidth,
      };
    });
    const previous = before.find(
      row => row.width === width && row.height === height,
    );
    assert.ok(value.toolbar.height <= 132, JSON.stringify(value));
    if (previous)
    {
      assert.ok(
        value.toolbar.height < previous.toolbar.height * 0.65,
        JSON.stringify({previous, value}),
      );
    }
    assert.ok(value.editor.height >= 140, JSON.stringify(value));
    assert.ok(value.results.height >= 140, JSON.stringify(value));
    assert.ok(value.results.bottom <= height + 1, JSON.stringify(value));
    assert.ok(value.run.bottom <= height, JSON.stringify(value));
    assert.equal(value.overflow, false);
    receipts.push({...value, previousToolbarHeight: previous?.toolbar.height});
    await page.screenshot({
      path: new URL(`${name}-compact-${width}x${height}.png`, output).pathname,
    });
  }
  await writeFile(
    new URL(`${name}-compact.json`, output),
    JSON.stringify(receipts, null, 2) + '\n',
  );
  await page.setViewportSize({width: 1440, height: 1000});
  await page.locator('[data-view=read]').evaluate(element => element.click());
}
