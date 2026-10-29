/** @file Check visible theme choices against actual OS changes and browser reloads. ref:REQ-learn-theme */
import assert from 'node:assert/strict';
/** Verify that appearance changes preserve the learner's code and results while updating Monaco and generated output. ref:REQ-learn-theme */
export async function verifyTheme(page, output, name)
{
  const choice = name =>
    page
      .locator('#theme-picker label')
      .filter({hasText: new RegExp('^' + name + '$')});
  const resolved = async theme =>
  {
    await page.waitForFunction(
      value => document.documentElement.dataset.theme === value,
      theme,
      {timeout: 30000},
    );
    const colors = await page.evaluate(() => ({
      page: getComputedStyle(document.body).backgroundColor,
      editor: getComputedStyle(
        document.querySelector('.monaco-editor .monaco-editor-background'),
      ).backgroundColor,
      scheme: getComputedStyle(document.documentElement).colorScheme,
    }));
    assert.equal(colors.scheme, theme);
    assert.equal(
      colors.editor,
      theme === 'dark' ? 'rgb(27, 37, 35)' : 'rgb(255, 255, 255)',
    );
    assert.equal(
      colors.page,
      theme === 'dark' ? 'rgb(20, 28, 27)' : 'rgb(247, 248, 243)',
    );
  };
  assert.deepEqual(
    await page.locator('#theme-picker label').allTextContents(),
    ['Auto', 'Light', 'Dark'],
  );
  assert.equal(
    await page.getByRole('radio', {name: 'Auto', exact: true}).isChecked(),
    true,
  );
  await page.emulateMedia({colorScheme: 'light'});
  await resolved('light');
  await page.getByRole('tab', {name: 'Laws', exact: true}).click();
  await page.getByText('Generated output (read only)', {exact: true}).click();
  await page
    .locator('#generated-files button')
    .filter({hasText: 'adapter/Adapter.fs'})
    .click();
  await page.waitForFunction(
    () => document.querySelector('#generated').textContent.includes('Adapter'),
    undefined,
    {timeout: 30000},
  );
  const snapshot = async () => ({
    source: await page.evaluate(async () =>
    {
      const {monaco} = await import('./vendor/editor.mjs');
      return monaco.editor.getModels()[0].getValue();
    }),
    status: await page.locator('#result-status').textContent(),
    outcomes: await page.locator('#outcomes').textContent(),
    generated: await page.locator('#generated').textContent(),
  });
  const before = await snapshot();
  const lightToken = await page
    .locator('#generated .mtk1')
    .first()
    .evaluate(element => getComputedStyle(element).color);
  await page.emulateMedia({colorScheme: 'dark'});
  await resolved('dark');
  await page.waitForFunction(
    color =>
    {
      const token = document.querySelector('#generated .mtk1');
      return token && getComputedStyle(token).color !== color;
    },
    lightToken,
    {timeout: 30000},
  );
  assert.deepEqual(
    await snapshot(),
    before,
    'theme changes preserve code, results and the selected generated file',
  );
  // Monaco repaints visible encoded tokens on a render frame after changing
  // its color map; wait for the source comment as well as generated output.
  await page.waitForFunction(
    () =>
    {
      const token = [
        ...document.querySelectorAll('.view-lines span[class^="mtk"]'),
      ].find(node => /^--/.test(node.textContent));
      return token && getComputedStyle(token).color === 'rgb(143, 183, 122)';
    },
    undefined,
    {timeout: 30000},
  );
  const commentContrast = await page.evaluate(() =>
  {
    const token = [
      ...document.querySelectorAll('.view-lines span[class^="mtk"]'),
    ].find(node => /^--/.test(node.textContent));
    if (!token)
    {
      throw new Error('Expected LawSpec source comment');
    }
    const luminance = color =>
      color
        .match(/[\d.]+/g)
        .slice(0, 3)
        .map(value => Number(value) / 255)
        .map(value =>
          value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4,
        )
        .reduce(
          (sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index],
          0,
        );
    const foreground = luminance(getComputedStyle(token).color),
      background = luminance(
        getComputedStyle(document.querySelector('.monaco-editor-background'))
          .backgroundColor,
      );
    return (
      (Math.max(foreground, background) + 0.05) /
      (Math.min(foreground, background) + 0.05)
    );
  });
  assert.ok(
    commentContrast >= 4.5,
    `Explanatory code comments need readable contrast: ${commentContrast}`,
  );
  await page.screenshot({
    path: new URL(`${name}-dark.png`, output).pathname,
    fullPage: true,
  });
  await page.setViewportSize({width: 390, height: 844});
  assert.equal(
    await page.evaluate(
      () => document.documentElement.scrollWidth <= innerWidth,
    ),
    true,
    'dark mobile layout',
  );
  await page.screenshot({
    path: new URL(`${name}-dark-mobile.png`, output).pathname,
    fullPage: true,
  });
  await page.setViewportSize({width: 1440, height: 1000});
  await choice('Light').click();
  await resolved('light');
  await page.emulateMedia({colorScheme: 'light'});
  await page.emulateMedia({colorScheme: 'dark'});
  await resolved('light');
  await page.reload();
  await page.waitForFunction(
    () => document.documentElement.dataset.ready === 'true',
  );
  await resolved('light');
  assert.equal(
    await page.getByRole('radio', {name: 'Light', exact: true}).isChecked(),
    true,
  );
  await choice('Dark').click();
  await resolved('dark');
  await page.emulateMedia({colorScheme: 'light'});
  await resolved('dark');
  await page.reload();
  await page.waitForFunction(
    () => document.documentElement.dataset.ready === 'true',
  );
  await resolved('dark');
  assert.equal(
    await page.getByRole('radio', {name: 'Dark', exact: true}).isChecked(),
    true,
  );
  await choice('Auto').click();
  await resolved('light');
  await page.getByRole('radio', {name: 'Auto', exact: true}).focus();
  await page.keyboard.press('ArrowRight');
  await resolved('light');
  assert.equal(
    await page.getByRole('radio', {name: 'Light', exact: true}).isChecked(),
    true,
    'native radio keyboard navigation',
  );
  await choice('Auto').click();
  await page.emulateMedia({colorScheme: 'dark'});
  await resolved('dark');
  await page.reload();
  await page.waitForFunction(
    () => document.documentElement.dataset.ready === 'true',
  );
  await resolved('dark');
  assert.equal(
    await page.getByRole('radio', {name: 'Auto', exact: true}).isChecked(),
    true,
  );
  await page.emulateMedia({colorScheme: 'light'});
  await resolved('light');
}
