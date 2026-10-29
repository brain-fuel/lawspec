import assert from 'node:assert/strict';

/** Follow the harness explanation into a real generator change and failure. ref:REQ-learn-harness-explanation */
export async function verifyHarness(browser, base)
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
    assert.match(
      await page.locator('#story').innerText(),
      /Harness configures generated test inputs/,
    );
    await page.getByRole('tab', {name: 'Harness', exact: true}).click();
    await page.locator('#harness-help summary').click();
    assert.match(
      await page.locator('#harness-explanation').innerText(),
      /no strategy yet/,
    );
    await page.getByRole('tab', {name: 'Laws', exact: true}).click();
    assert.equal(await page.locator('#harness-help').isVisible(), false);
    await page.locator('#stage [data-stage="3"]').click();
    await page.waitForFunction(() => location.hash.includes('scene=swap'));
    assert.match(
      await page.locator('#story').innerText(),
      /harness supplies its inputs/,
    );
    await page.getByRole('tab', {name: 'Harness', exact: true}).click();
    assert.match(
      await page.locator('#harness-explanation').innerText(),
      /law permits -10 through 10/,
    );
    for (const language of ['TypeScript', 'JavaScript', 'F#'])
    {
      await page.getByRole('tab', {name: language, exact: true}).click();
      await page.getByRole('tab', {name: 'Harness', exact: true}).click();
      assert.match(
        await page.locator('#harness-explanation').innerText(),
        /use numbers for x/,
      );
    }
    await page.locator('#lessons [data-lesson="wlaschin-shrink"]').click();
    await page.waitForFunction(() =>
      location.hash.includes('lesson=wlaschin-shrink'),
    );
    await page.getByRole('tab', {name: 'Harness', exact: true}).click();
    assert.match(
      await page.locator('#harness-explanation').innerText(),
      /0 through 79/,
    );
    const readSource = () =>
      page.evaluate(async () =>
      {
        const {monaco} = await import('./vendor/editor.mjs');
        return monaco.editor.getModels()[0].getValue();
      });
    const original = await readSource();
    assert.match(original, /n <= 79/);
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
    assert.match(await run(), /passed/i);
    await page.evaluate(async () =>
    {
      const {monaco} = await import('./vendor/editor.mjs');
      const model = monaco.editor.getModels()[0];
      const source = model.getValue();
      if (!source.includes('n <= 79'))
      {
        throw new Error('Missing narrow generator');
      }
      model.setValue(source.replace('n <= 79', 'n <= 200'));
    });
    assert.match(
      await page.locator('#harness-explanation').innerText(),
      /edited source above determines the inputs/,
    );
    assert.match(await run(), /failure/i);
    assert.match(await page.locator('#outcomes').innerText(), /80/);
    for (const [width, height] of [
      [1440, 1000],
      [390, 844],
      [1024, 600],
    ])
    {
      await page.setViewportSize({width, height});
      if (width < 1100 || height < 720)
      {
        await page.locator('[data-view="code"]').click();
      }
      await page
        .locator('#harness-help')
        .evaluate(element => (element.open = true));
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
      const geometry = await page.evaluate(() => ({
        overflow: document.documentElement.scrollWidth > innerWidth,
        run: document.querySelector('#run').getBoundingClientRect().bottom,
        editor: document.querySelector('#editor').getBoundingClientRect()
          .height,
        help: document.querySelector('#harness-help').getBoundingClientRect()
          .height,
        height: innerHeight,
      }));
      assert.equal(geometry.overflow, false);
      assert.ok(geometry.run < geometry.height, JSON.stringify(geometry));
      assert.ok(geometry.editor >= 140, JSON.stringify(geometry));
      assert.ok(geometry.help >= 38, JSON.stringify(geometry));
    }
  }
  finally
  {
    await context.close();
  }
}
