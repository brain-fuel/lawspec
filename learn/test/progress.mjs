/** @file Exercise backups against real drafts and kept regression laws. ref:REQ-learn-course-hierarchy ref:REQ-learn-regression-progress */
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
/** Restore matching drafts atomically while retaining later work and appearance. ref:REQ-learn-course-hierarchy */
export async function verifyProgress(page, course)
{
  const legacy = await page.context().newPage(),
    errors = [];
  legacy.on('pageerror', error => errors.push(error.message));
  const addition = course.lessons[0],
    other = course.lessons.at(-1);
  const address = (lesson, track, stage = lesson.stages[0]) =>
  {
    const url = new URL(page.url());
    url.hash = new URLSearchParams({
      course: course.version,
      lesson: lesson.id,
      scene: stage.id,
      language: 'javascript',
      track,
    });
    return url.href;
  };
  const visit = async url =>
  {
    await legacy.goto('about:blank');
    await legacy.goto(url);
    await legacy.waitForFunction(
      () => document.documentElement.dataset.ready === 'true',
    );
  };
  const source = () =>
    legacy.evaluate(async () =>
    {
      const {monaco} = await import('./vendor/editor.mjs');
      return monaco.editor.getModels()[0].getValue();
    });
  const select = async () =>
    legacy.locator('#files [data-file="Solution.js"]').click();
  const edit = async value =>
  {
    await select();
    await legacy.evaluate(async text =>
    {
      const {monaco} = await import('./vendor/editor.mjs');
      monaco.editor.getModels()[0].setValue(text);
    }, value);
    await legacy.waitForFunction(
      () =>
        document.querySelector('#save-status').textContent ===
        'Saved on device',
    );
  };
  const restore = async backup =>
  {
    if (
      !(await legacy
        .locator('#progress-panel')
        .evaluate(element => element.open))
    )
    {
      await legacy.locator('#progress-panel>summary').click();
    }
    const choosing = legacy.waitForEvent('filechooser');
    await legacy.locator('#restore').click();
    const chooser = await choosing;
    await chooser.setFiles({
      name: 'progress.json',
      mimeType: 'application/json',
      buffer: Buffer.from(JSON.stringify(backup)),
    });
  };
  try
  {
    const regressionStage = other.stages[1],
      regressionURL = address(other, 'booking', regressionStage),
      regressionKey = [
        course.version,
        other.id,
        'booking',
        'javascript',
        regressionStage.id,
      ].join('/');
    await visit(regressionURL);
    await legacy.locator('#run').click();
    await legacy.waitForFunction(
      () => document.querySelector('#cancel').disabled,
      null,
      {timeout: 120000},
    );
    assert.equal(await legacy.locator('#regression').isEnabled(), true);
    await legacy.locator('#regression').click();
    await legacy.waitForFunction(
      () =>
        document.querySelector('#save-status').textContent ===
        'Saved on device',
    );
    const keptRegression = await source();
    assert.match(keptRegression, /law "\|keep this counterexample\| is/);
    assert.match(keptRegression, /unique \[0\] = \[0\]/);
    await visit(regressionURL);
    await legacy.getByRole('tab', {name: 'Laws', exact: true}).click();
    assert.equal(
      await source(),
      keptRegression,
      'kept case survives reload through autosave',
    );
    await visit(address(addition, 'shared'));
    await legacy.locator('#load-stage').click();
    await legacy.waitForFunction(
      () =>
        document.querySelector('#save-status').textContent ===
        'Saved on device',
    );
    await visit(address(addition, 'booking'));
    const original =
        addition.solutions.javascript['Solution.js'] +
        '\n// Backed-up notebook draft.\n',
      later = original + '// Later edit.\n';
    await edit(original);
    await legacy.locator('#progress-panel>summary').click();
    assert.match(
      await legacy.locator('#saved-notebook').textContent(),
      /Event booking/,
    );
    const downloading = legacy.waitForEvent('download');
    await legacy.locator('#export').click();
    const download = await downloading;
    assert.equal(
      download.suggestedFilename(),
      `lawspec-learn-progress-${course.version}.json`,
    );
    const backup = JSON.parse(await readFile(await download.path(), 'utf8'));
    const key = [
      course.version,
      addition.id,
      'booking',
      'javascript',
      addition.stages[0].id,
    ].join('/');
    assert.equal(
      backup.drafts.find(row => row.key === key).value.files['Solution.js'],
      original,
    );
    assert.ok(backup.drafts.some(row => row.key.includes('/shared/')));
    assert.equal(
      backup.drafts.find(row => row.key === regressionKey).value.files[
        'Tests.lawspec'
      ],
      keptRegression,
      'backup includes the kept case from another lesson and step',
    );
    assert.ok(backup.codeLicenses.length);
    for (const row of backup.drafts)
    {
      assert.equal(Object.hasOwn(row.value, 'results'), false);
      assert.equal(Object.hasOwn(row.value, 'seed'), false);
    }
    assert.equal(Object.hasOwn(backup, 'theme'), false);
    await visit(regressionURL);
    await legacy.locator('#load-stage').click();
    await legacy.waitForFunction(
      () =>
        document.querySelector('#save-status').textContent ===
        'Saved on device',
    );
    await legacy.getByRole('tab', {name: 'Laws', exact: true}).click();
    assert.doesNotMatch(await source(), /law "\|keep this counterexample\| is/);
    await visit(address(addition, 'booking'));
    await edit(later);
    const retained =
      other.solutions.javascript['Solution.js'] +
      '\n// Created after backup.\n';
    await visit(address(other, 'library'));
    await edit(retained);
    await visit(address(addition, 'booking'));
    await select();
    assert.equal(await source(), later);
    await legacy
      .locator('#theme-picker label')
      .filter({hasText: /^Dark$/})
      .click();
    const invalid = structuredClone(backup);
    invalid.drafts.find(row => row.key === key).value.files['Solution.js'] =
      'must not overwrite the valid draft';
    invalid.drafts.push({key: 'invalid', value: {}});
    await restore(invalid);
    await legacy.waitForFunction(() =>
      document
        .querySelector('#progress-status')
        .textContent.startsWith('Restore failed'),
    );
    await visit(address(addition, 'booking'));
    await select();
    assert.equal(
      await source(),
      later,
      'invalid backup changes no saved draft',
    );
    await restore(backup);
    await legacy.waitForFunction(() =>
      document
        .querySelector('#progress-status')
        .textContent.includes('restored'),
    );
    await select();
    assert.equal(
      await source(),
      original,
      'matching saved notebook is restored',
    );
    assert.equal(
      await legacy.getByRole('radio', {name: 'Dark', exact: true}).isChecked(),
      true,
    );
    assert.match(
      await legacy.locator('#result-status').textContent(),
      /no current run/,
    );
    await visit(regressionURL);
    await legacy.getByRole('tab', {name: 'Laws', exact: true}).click();
    assert.equal(
      await source(),
      keptRegression,
      'restore recovers the removed regression',
    );
    assert.match(
      await legacy.locator('#result-status').innerText(),
      /no current run/,
    );
    await legacy.locator('#run-options>summary').click();
    await legacy.locator('#examples').click();
    await legacy.waitForFunction(
      () => document.querySelector('#cancel').disabled,
      null,
      {timeout: 120000},
    );
    assert.match(
      await legacy
        .locator('#outcomes .failed')
        .allTextContents()
        .then(rows => rows.join('\n')),
      /keep this counterexample/,
      'the restored regression actually runs and detects the unchanged bug',
    );
    await visit(address(other, 'library'));
    await select();
    assert.equal(
      await source(),
      retained,
      'work created after backup is preserved',
    );
    await legacy
      .locator('#theme-picker label')
      .filter({hasText: /^Auto$/})
      .click();
    await legacy.locator('#progress-panel>summary').click();
    let failedBackupDownloads = 0;
    legacy.on('download', () => failedBackupDownloads++);
    await legacy.evaluate(() =>
    {
      IDBObjectStore.prototype.put = () =>
      {
        throw new Error('backup persistence unavailable');
      };
    });
    await legacy.locator('#export').click();
    await legacy.waitForFunction(() =>
      document
        .querySelector('#progress-status')
        .textContent.startsWith('Backup failed:'),
    );
    assert.equal(
      failedBackupDownloads,
      0,
      'failed persistence cannot produce an older backup that omits the latest work',
    );
    assert.deepEqual(errors, []);
  }
  finally
  {
    await legacy.close();
  }
}
