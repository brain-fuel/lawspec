import assert from 'node:assert/strict';
import {course} from './helpers.mjs';

/** Preserve source selection across languages without mixing independent drafts. ref:REQ-learn-source-selection */
export async function verifySourceTabs(browser, base)
{
  const context = await browser.newContext({
    viewport: {width: 1440, height: 1000},
  });
  try
  {
    const page = await context.newPage();
    await page.goto(base);
    await page.waitForFunction(
      () => document.documentElement.dataset.ready === 'true',
    );
    assert.deepEqual(
      await page.locator('#files [role=tab]').allTextContents(),
      ['Laws', 'Solution', 'Harness'],
    );
    const languages = [
      ['fsharp', 'F#', 'fs'],
      ['typescript', 'TypeScript', 'ts'],
      ['javascript', 'JavaScript', 'js'],
    ];
    const switchLanguage = async ([id, name]) =>
    {
      const tab = page.getByRole('tab', {name, exact: true});
      if ((await tab.getAttribute('aria-selected')) !== 'true')
      {
        await tab.click();
        await page.waitForFunction(
          value => location.hash.includes('language=' + value),
          id,
        );
      }
    };
    const source = () =>
      page.evaluate(async () =>
      {
        const {monaco} = await import('./vendor/editor.mjs');
        const model = monaco.editor.getModels()[0];
        return {text: model.getValue(), language: model.getLanguageId()};
      });
    for (const label of ['Laws', 'Solution', 'Harness'])
    {
      await switchLanguage(languages[0]);
      await page.getByRole('tab', {name: label, exact: true}).click();
      const drafts = new Map();
      for (const row of languages)
      {
        const [id, , ext] = row;
        await switchLanguage(row);
        const file =
          label === 'Solution'
            ? 'Solution.' + ext
            : label === 'Laws'
              ? 'Tests.lawspec'
              : 'Harness.lawspec';
        assert.equal(
          await page.locator('#files [aria-selected=true]').innerText(),
          label,
        );
        assert.equal(await page.locator('#current-file').textContent(), file);
        const current = await source();
        assert.equal(current.language, label === 'Solution' ? id : 'lawspec');
        assert.equal(
          current.text,
          course.lessons[0].stages[0].projects[id][file],
        );
        const text =
          current.text +
          '\n' +
          (label === 'Solution' ? '//' : '--') +
          ' draft for ' +
          id +
          ' ' +
          label +
          '\n';
        drafts.set(id, text);
        await page.evaluate(async text =>
        {
          const {monaco} = await import('./vendor/editor.mjs');
          monaco.editor.getModels()[0].setValue(text);
        }, text);
        await page.waitForFunction(
          () =>
            document.querySelector('#save-status').textContent ===
            'Saved on device',
        );
      }
      for (const row of [...languages, languages[0]])
      {
        await switchLanguage(row);
        assert.equal(
          await page.locator('#files [aria-selected=true]').innerText(),
          label,
        );
        assert.equal((await source()).text, drafts.get(row[0]));
      }
    }
    // Keyboard language navigation must use the same preservation behavior.
    await page.getByRole('tab', {name: 'F#', exact: true}).focus();
    await page.keyboard.press('ArrowRight');
    await page.waitForFunction(() =>
      location.hash.includes('language=typescript'),
    );
    assert.equal(
      await page.locator('#files [aria-selected=true]').innerText(),
      'Harness',
    );
    // Selecting another scene still opens the file discussed by that scene.
    await page.locator('#next-scene').click();
    await page.waitForFunction(() =>
      location.hash.includes('scene=second-promise'),
    );
    assert.equal(
      await page.locator('#files [aria-selected=true]').innerText(),
      'Solution',
    );
    assert.equal(
      await page.locator('#current-file').textContent(),
      'Solution.ts',
    );
    await page.setViewportSize({width: 390, height: 844});
    await page.locator('[data-view=code]').click();
    await page.getByRole('tab', {name: 'Laws', exact: true}).click();
    await switchLanguage(languages[2]);
    assert.equal(await page.locator('#code-panel').isVisible(), true);
    assert.equal(
      await page.locator('#files [aria-selected=true]').innerText(),
      'Laws',
    );
    for (const [stage, scope, counts] of [
      [0, 'Examples + boundaries', /[1-9]\d* checks? · \d+ ms/],
      [4, 'Sampled properties', /1 sampled property · 100 generated trials/],
      [
        3,
        'All checks',
        /[1-9]\d* sampled propert(?:y|ies) · [1-9]\d* generated trials/,
      ],
    ])
    {
      await page.setViewportSize({width: 1440, height: 1000});
      await page.locator(`#stage [data-stage="${stage}"]`).click();
      await page.waitForFunction(
        expected =>
          document.querySelector('#run-scope').textContent === expected,
        scope,
      );
      assert.equal(await page.locator('#run').innerText(), 'Run checks');
      if (stage === 0)
      {
        await page.setViewportSize({width: 390, height: 844});
        await page.locator('[data-view=code]').click();
      }
      await page.getByRole('button', {name: 'Run checks', exact: true}).click();
      assert.equal(await page.locator('#run').innerText(), 'Run checks');
      const geometry = await page.evaluate(() => ({
        overflow: document.documentElement.scrollWidth > innerWidth,
        run: document.querySelector('#run').getBoundingClientRect().right,
        cancel: document.querySelector('#cancel').getBoundingClientRect().right,
        width: innerWidth,
      }));
      assert.equal(geometry.overflow, false);
      assert.ok(geometry.run <= geometry.width, JSON.stringify(geometry));
      assert.ok(geometry.cancel <= geometry.width, JSON.stringify(geometry));
      await page.waitForFunction(
        () => document.querySelector('#cancel').disabled,
        null,
        {timeout: 120000},
      );
      assert.match(await page.locator('#message').innerText(), counts);
      if (stage === 4)
      {
        assert.doesNotMatch(
          await page.locator('#outcomes').innerText(),
          /one plus two is three|two plus two is four/,
          'sampled mode omits the concrete examples, while its property runner can still have a name',
        );
      }
      else
      {
        assert.match(
          await page.locator('#outcomes').innerText(),
          /one plus two is three/,
        );
      }
      assert.equal(await page.locator('#run').innerText(), 'Run checks');
      assert.equal(await page.locator('#run-scope').innerText(), scope);
    }
  }
  finally
  {
    await context.close();
  }
}
