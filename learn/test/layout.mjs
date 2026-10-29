/** @file Exercise the read/edit/run loop with real viewport and scroll geometry. ref:REQ-learn-workspace-focus */
import assert from 'node:assert/strict';
import {course} from './helpers.mjs';
/** Keep the current source, execution controls and step navigation reachable without scrolling the whole page. ref:REQ-learn-workspace-focus */
export async function verifyLayout(page, output, name)
{
  const view = async selected =>
  {
    await page.locator(`#workspace-views [data-view=${selected}]`).click();
    await page.waitForFunction(
      value => document.documentElement.dataset.workspaceView === value,
      selected,
    );
  };
  const geometry = () =>
    page.evaluate(() =>
    {
      const rect = id =>
      {
        const {top, bottom, height} = document
          .getElementById(id)
          .getBoundingClientRect();
        return {top, bottom, height};
      };
      const {top, bottom, height} = document
        .querySelector('.results')
        .getBoundingClientRect();
      return {
        viewport: innerHeight,
        pageY: scrollY,
        pageHeight: document.documentElement.scrollHeight,
        pageWidth: document.documentElement.scrollWidth,
        width: innerWidth,
        run: rect('run'),
        next: rect('next-scene'),
        editor: rect('editor'),
        results: {top, bottom, height},
      };
    });
  const fits = async () =>
  {
    const value = await geometry();
    assert.equal(value.pageY, 0);
    assert.ok(value.pageHeight <= value.viewport + 1, JSON.stringify(value));
    assert.ok(value.pageWidth <= value.width, JSON.stringify(value));
    return value;
  };
  const run = async () =>
  {
    await page.locator('#run').click();
    await page.waitForFunction(
      () => document.querySelector('#cancel').disabled,
    );
    return page.locator('#result-status').textContent();
  };
  const first = page.locator('#symbol');
  assert.equal(await first.isVisible(), true);
  await page.setViewportSize({width: 1440, height: 900});
  assert.equal(await run(), 'Checks passed');
  const initial = await fits();
  assert.ok(initial.results.height >= 140);
  assert.ok(initial.results.bottom <= initial.viewport);
  assert.ok(initial.editor.height >= 100);
  await page.locator('#lesson-reader').evaluate(element =>
  {
    element.scrollTop = element.scrollHeight;
  });
  assert.ok(
    (await page
      .locator('#lesson-reader')
      .evaluate(element => element.scrollTop)) > 0,
  );
  const scrolled = await fits();
  assert.equal(scrolled.run.top, initial.run.top);
  assert.equal(scrolled.editor.top, initial.editor.top);
  assert.equal(scrolled.next.top, initial.next.top);
  assert.ok(scrolled.next.bottom <= scrolled.viewport);
  await page.locator('#next-scene').click();
  await page.waitForFunction(() =>
    location.hash.includes('scene=second-promise'),
  );
  assert.equal(
    await page.locator('#lesson-reader').evaluate(element => element.scrollTop),
    0,
  );
  assert.equal(
    await page.locator('#symbol').isVisible(),
    false,
    'the opening prediction is absent from the next step',
  );
  assert.equal(
    await page.evaluate(() => document.activeElement.id),
    'stage-title',
  );
  assert.equal(await run(), 'Check the failure');
  await page.screenshot({
    path: new URL(`${name}-workspace.png`, output).pathname,
  });
  await page.setViewportSize({width: 1280, height: 720});
  const laptop = await fits();
  assert.ok(
    laptop.results.bottom <= laptop.viewport + 1,
    JSON.stringify(laptop),
  );
  assert.ok(laptop.results.height >= 140, JSON.stringify(laptop));
  assert.ok(laptop.editor.height >= 100);
  await page.setViewportSize({width: 390, height: 844});
  await fits();
  assert.deepEqual(
    (await page.locator('#workspace-views [role=tab]').allTextContents()).map(
      text => text.trim(),
    ),
    ['Course', 'Read', 'Code & results'],
  );
  await page.locator('#lesson-reader').evaluate(element =>
  {
    element.scrollTop = 140;
  });
  const readPosition = await page
    .locator('#lesson-reader')
    .evaluate(element => element.scrollTop);
  assert.ok(readPosition > 0);
  await view('code');
  assert.equal(await page.locator('#code-panel').isVisible(), true);
  assert.equal(await page.locator('#lesson-panel').isVisible(), false);
  assert.equal(
    await page.locator('#result-status').textContent(),
    'Check the failure',
  );
  const model = await page.evaluate(async () =>
  {
    const {monaco} = await import('./vendor/editor.mjs');
    return {
      id: monaco.editor.getModels()[0].id,
      source: monaco.editor.getModels()[0].getValue(),
    };
  });
  await page.getByText('Diagnostics & evidence', {exact: true}).click();
  await page.locator('.results').evaluate(element =>
  {
    element.scrollTop = 120;
  });
  const resultPosition = await page
    .locator('.results')
    .evaluate(element => element.scrollTop);
  assert.ok(resultPosition > 0);
  await view('read');
  assert.equal(
    await page.locator('#lesson-reader').evaluate(element => element.scrollTop),
    readPosition,
  );
  await view('code');
  assert.equal(
    await page.locator('.results').evaluate(element => element.scrollTop),
    resultPosition,
  );
  assert.deepEqual(
    await page.evaluate(async () =>
    {
      const {monaco} = await import('./vendor/editor.mjs');
      return {
        id: monaco.editor.getModels()[0].id,
        source: monaco.editor.getModels()[0].getValue(),
      };
    }),
    model,
  );
  await page.getByRole('tab', {name: 'TypeScript', exact: true}).click();
  await page.waitForFunction(() =>
    location.hash.includes('language=typescript'),
  );
  assert.equal(
    await page.locator('#code-panel').isVisible(),
    true,
    'language switches stay in the Code view',
  );
  await page.screenshot({
    path: new URL(`${name}-workspace-mobile.png`, output).pathname,
  });
  await view('read');
  await page.locator('#workspace-views [data-view=read]').focus();
  await page.keyboard.press('ArrowRight');
  assert.equal(await page.locator('#code-panel').isVisible(), true);
  await view('course');
  assert.equal(await page.locator('#lessons').isVisible(), true);
  await page.locator('#lessons button[data-lesson]').nth(1).click();
  await page.waitForFunction(() =>
    location.hash.includes('lesson=wlaschin-sort'),
  );
  assert.equal(
    await page.locator('#lesson-panel').isVisible(),
    true,
    'choosing a course starts its story',
  );
  assert.equal(
    await page.locator('#symbol').innerText(),
    course.lessons[1].stages[0].symbol,
    'each lesson uses its own authored first-step illustration',
  );
  assert.notEqual(
    await page.locator('#symbol').innerText(),
    course.lessons[0].stages[0].symbol,
    'the sorting lesson does not inherit the calculator prediction',
  );
  await page.locator('#story-file').click();
  assert.equal(
    await page.locator('#code-panel').isVisible(),
    true,
    'source links go straight to the editor',
  );
  await page.setViewportSize({width: 1366, height: 600});
  await fits();
  const runBefore = await page.locator('#run').boundingBox();
  await page.locator('#code-panel').evaluate(element =>
  {
    element.scrollTop = element.scrollHeight;
  });
  const runAfter = await page.locator('#run').boundingBox();
  assert.ok(runAfter.y >= 0 && runAfter.y + runAfter.height < 600);
  assert.ok(
    Math.abs(runAfter.y - runBefore.y) < 40,
    'Run stays in the short-window toolbar',
  );
  await view('course');
  await page.locator('#stage [data-stage="1"]').click();
  await page.waitForFunction(() => location.hash.includes('scene=preserve'));
  await view('code');
  assert.equal(await run(), 'Check the failure');
  assert.equal(
    await page.locator('#run-options').evaluate(element => element.open),
    true,
    'real failures expose replay controls',
  );
  const failure = await fits();
  assert.ok(
    failure.results.bottom <= failure.viewport,
    JSON.stringify(failure),
  );
  assert.ok(failure.results.height >= 140);
  assert.ok(failure.editor.height >= 140);
  await page.screenshot({
    path: new URL(`${name}-workspace-short-failure.png`, output).pathname,
  });
  await page.setViewportSize({width: 1440, height: 1000});
  await page.locator('#lessons button[data-lesson]').nth(0).click();
  await page.waitForFunction(() =>
    location.hash.includes('lesson=wlaschin-add'),
  );
  await page.getByRole('tab', {name: 'F#', exact: true}).click();
  await page.waitForFunction(() => location.hash.includes('language=fsharp'));
}
