// Exercise the packaged app itself in all three browser engines.
import assert from 'node:assert/strict';
import {chromium, firefox, webkit} from '@playwright/test';
import {existsSync} from 'node:fs';
import {mkdir, writeFile, readdir, readFile} from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {serveLearn} from '../../npm/learn.mjs';
import {course} from './helpers.mjs';
import {verifyTheme} from './theme.mjs';
import {verifyLayout} from './layout.mjs';
import {verifyCourseNavigation} from './navigation.mjs';
import {verifyProgress} from './progress.mjs';
import {verifyHarness} from './harness.mjs';
import {verifySourceTabs} from './tabs.mjs';
import {verifyNoviceExperience} from './novice.mjs';
import {observeWorkers, verifyFormatting} from './formatting.mjs';
/** Keep browser evidence and screenshots separate from course source. ref:REQ-learn-local-execution ref:REQ-learn-visible-workspace */
const output = new URL('../../.artifacts/learn-preview/', import.meta.url);
await mkdir(output, {recursive: true});
/** Exercise the packaged manifest-free loopback server. ref:REQ-learn-local-execution ref:REQ-learn-visible-workspace */
const server = await serveLearn(0, {quiet: true});
/** Bind every allowed network observation to this test server. ref:REQ-learn-local-execution ref:REQ-learn-visible-workspace */
const base = `http://127.0.0.1:${server.address().port}`;
/** Preserve actual browser versions, outcomes and measured costs. ref:REQ-learn-local-execution ref:REQ-learn-visible-workspace */
const receipts = [];
/** Launch each required engine; absence is a failure rather than a skipped claim. ref:REQ-learn-local-execution ref:REQ-learn-visible-workspace */
async function launch(type, name)
{
  const override = process.env[`LAWSPEC_${name.toUpperCase()}_EXECUTABLE`];
  if (override)
  {
    return type.launch({executablePath: override});
  }
  if (existsSync(type.executablePath()))
  {
    return type.launch();
  }
  // Local CI may retain a newer browser between pinned test-runner updates.
  // Record its actual version; no engine is skipped when the default is absent.
  const cache =
    process.env.PLAYWRIGHT_BROWSERS_PATH ??
    path.join(os.homedir(), 'Library/Caches/ms-playwright');
  const candidates = (await readdir(cache))
    .filter(item =>
      item.startsWith(
        (name === 'chromium' ? 'chromium_headless_shell' : name) + '-',
      ),
    )
    .sort((a, b) => Number(b.split('-').at(-1)) - Number(a.split('-').at(-1)));
  for (const candidate of candidates)
  {
    const executable = path.join(
      cache,
      candidate,
      name === 'chromium'
        ? 'chrome-headless-shell-mac-arm64/chrome-headless-shell'
        : name === 'firefox'
          ? 'firefox/Nightly.app/Contents/MacOS/firefox'
          : 'pw_run.sh',
    );
    if (existsSync(executable))
    {
      return type.launch({executablePath: executable});
    }
  }
  throw new Error(
    `Install ${name} with npx --prefix learn playwright install ${name}`,
  );
}
try
{
  for (const [name, type] of [
    ['chromium', chromium],
    ['firefox', firefox],
    ['webkit', webkit],
  ])
  {
    const browser = await launch(type, name);
    const context = await browser.newContext({
      viewport: {width: 1440, height: 1000},
      acceptDownloads: true,
    });
    try
    {
      if (process.env.LAWSPEC_LEARN_NOVICE_ONLY)
      {
        await verifyNoviceExperience(browser, base);
        receipts.push({
          browser: name,
          version: browser.version(),
          checks: [
            'phrase-name typing and execution',
            'readable claims and actual calls',
            'trial counts and shrink disclosure',
            'draft preservation and source-replacement undo',
          ],
        });
        console.log(
          `${name}: first-time learner and English-name checks passed`,
        );
        continue;
      }
      if (!process.env.LAWSPEC_LEARN_FORMATTING_ONLY)
      {
        await verifyNoviceExperience(browser, base);
      }
      if (process.env.LAWSPEC_LEARN_PROGRESS_ONLY)
      {
        const page = await context.newPage();
        await page.goto(base);
        await page.waitForFunction(
          () => document.documentElement.dataset.ready === 'true',
        );
        await verifyProgress(page, course);
        receipts.push({
          browser: name,
          version: browser.version(),
          checks: [
            'all saved notebooks in backup',
            'kept regression survives reload, backup and restore',
            'restored regression executes against the implementation',
            'failed persistence prevents stale backup',
            'matching draft replacement',
            'unrelated later drafts preserved',
            'invalid restore atomicity',
            'theme and execution evidence excluded',
          ],
        });
        console.log(`${name}: progress and regression backup checks passed`);
        continue;
      }
      if (process.env.LAWSPEC_LEARN_TABS_ONLY)
      {
        await verifySourceTabs(browser, base);
        receipts.push({
          name,
          version: browser.version(),
          checks: [
            'source selection across languages',
            'independent drafts',
            'keyboard and compact navigation',
          ],
        });
        console.log(
          name + ': source tab selection and independent drafts passed',
        );
        continue;
      }
      if (!process.env.LAWSPEC_LEARN_FORMATTING_ONLY)
      {
        await verifySourceTabs(browser, base);
        await verifyHarness(browser, base);
        console.log(name + ': harness explanation and generator edit passed');
        if (process.env.LAWSPEC_LEARN_HARNESS_ONLY)
        {
          receipts.push({
            name,
            version: browser.version(),
            checks: [
              'harness explanation',
              'generator edit changes real result',
              'compact harness layout',
            ],
          });
          continue;
        }
      }
      const requests = [],
        errors = [];
      context.on('request', request =>
        requests.push({
          url: request.url(),
          method: request.method(),
          body: request.postData(),
        }),
      );
      const page = await context.newPage();
      await observeWorkers(page);
      page.on('pageerror', error => errors.push(error.message));
      const started = performance.now();
      await page.goto(base);
      await page.waitForFunction(
        () => document.documentElement.dataset.ready === 'true',
      );
      const ready = performance.now() - started;
      await page.evaluate(() => document.fonts.ready);
      assert.equal(
        await page.locator('select').count(),
        0,
        'course and file choices are visible controls',
      );
      const typography = await page.evaluate(() => ({
        heading: getComputedStyle(document.querySelector('h1')).fontFamily,
        body: getComputedStyle(document.body).fontFamily,
        code: getComputedStyle(document.querySelector('.view-lines'))
          .fontFamily,
        loaded:
          document.fonts.check('600 24px Overpass') &&
          document.fonts.check('16px "Atkinson Hyperlegible"') &&
          document.fonts.check('14px "Atkinson Hyperlegible Mono"'),
      }));
      assert.match(typography.heading, /Overpass/);
      assert.match(typography.body, /Atkinson Hyperlegible/);
      assert.match(typography.code, /Atkinson Hyperlegible Mono/);
      assert.equal(typography.loaded, true);
      assert.deepEqual(
        await page.locator('#files [role=tab]').allTextContents(),
        ['Laws', 'Solution', 'Harness'],
      );
      await page.locator('#files [role=tab]').filter({hasText: 'Laws'}).click();
      assert.equal(
        await page.locator('#current-file').textContent(),
        'Tests.lawspec',
      );
      await page.keyboard.press('ArrowRight');
      assert.equal(
        await page.locator('#current-file').textContent(),
        'Solution.fs',
      );
      const edit = async (file, source) =>
      {
        await page.locator(`#files button[data-file="${file}"]`).click();
        await page.evaluate(async text =>
        {
          const {monaco} = await import('./vendor/editor.mjs');
          monaco.editor.getModels()[0].setValue(text);
        }, source);
        await page.waitForFunction(
          () =>
            document.querySelector('#save-status').textContent ===
            'Saved on device',
        );
      };
      const run = async (id = 'run') =>
      {
        if (
          id !== 'run' &&
          !(await page
            .locator('#run-options')
            .evaluate(element => element.open))
        )
        {
          await page.locator('#run-options>summary').click();
        }
        await page.locator('#' + id).click();
        await page.waitForFunction(
          () => document.querySelector('#cancel').disabled,
          undefined,
          {timeout: 120000},
        );
        return page.locator('#result-status').textContent();
      };
      const highlight = await page.evaluate(async () =>
      {
        const {monaco} = await import('./vendor/editor.mjs');
        return monaco.editor
          .tokenize(
            '-- note\nunit demo\nseats :: Int32 -> Int32\nlaw rule is\n definition:\n for all (n :: Int32) => n = 4\n end for all\n end definition\nend law\n"hello"',
            'lawspec',
          )
          .flat()
          .map(row => row.type);
      });
      for (const type of [
        'comment.lawspec',
        'keyword.lawspec',
        'type.lawspec',
        'number.lawspec',
        'string.lawspec',
      ])
      {
        assert.ok(highlight.includes(type), `${name} missing ${type}`);
      }
      // Exercise repeat generation in independent real browser workers, not only the Node esbuild host.
      const repeatGeneration =
        process.env.LAWSPEC_LEARN_THEME_ONLY ||
        process.env.LAWSPEC_LEARN_LAYOUT_ONLY ||
        process.env.LAWSPEC_LEARN_FORMATTING_ONLY
          ? 'formatting.json'
          : process.env.LAWSPEC_LEARN_PROGRESS_ONLY
            ? []
            : await page.evaluate(
                async projects =>
                  {
                  const hash = async value =>
                    Array.from(
                      new Uint8Array(
                        await crypto.subtle.digest(
                          'SHA-256',
                          new TextEncoder().encode(JSON.stringify(value)),
                        ),
                      ),
                    )
                      .map(x => x.toString(16).padStart(2, '0'))
                      .join('');
                  const compile = async request =>
                    {
                    const worker = new Worker(
                      new URL('./compile-worker.mjs', location.href),
                      {type: 'module'},
                    );
                    try
                      {
                      return await new Promise((resolve, reject) =>
                        {
                        const timer = setTimeout(
                          () =>
                            reject(new Error('Determinism check timed out')),
                          120000,
                        );
                        worker.onmessage = ({data}) =>
                          {
                          clearTimeout(timer);
                          data.error
                            ? reject(new Error(data.error))
                            : resolve(data.result);
                        };
                        worker.onerror = reject;
                        worker.postMessage(request);
                      });
                    }
                    finally
                      {
                      worker.terminate();
                    }
                  };
                  const receipts = [];
                  for (const [language, files] of Object.entries(projects))
                    {
                    const request = {
                      language,
                      files,
                      mode: 'all',
                      seed: 424242,
                    };
                    const first = await compile(request),
                      second = await compile(request);
                    if (!first.code || !second.code)
                      {
                      throw new Error(
                        JSON.stringify([first.diagnostics, second.diagnostics]),
                      );
                    }
                    const canonical = result => ({
                      binding: result.binding,
                      generated: [...result.generated].sort((a, b) =>
                        a.path < b.path ? -1 : a.path > b.path ? 1 : 0,
                      ),
                      code: result.code,
                    });
                    receipts.push({
                      language,
                      first: await hash(canonical(first)),
                      second: await hash(canonical(second)),
                    });
                  }
                  return receipts;
                },
                Object.fromEntries(
                  ['fsharp', 'typescript', 'javascript'].map(language => [
                    language,
                    {...course.lessons[0].solutions[language]},
                  ]),
                ),
              );
      for (const receipt of repeatGeneration)
      {
        assert.equal(
          receipt.first,
          receipt.second,
          `${name}/${receipt.language} fresh worker determinism`,
        );
      }
      const firstRunStart = performance.now();
      assert.equal(await run(), 'Checks passed');
      const firstCompilationAndExamplesMilliseconds = Math.round(
        performance.now() - firstRunStart,
      );
      await verifyFormatting(page);
      if (process.env.LAWSPEC_LEARN_FORMATTING_ONLY)
      {
        assert.deepEqual(errors, []);
        for (const request of requests.filter(row =>
          /^https?:/.test(row.url),
        ))
        {
          assert.equal(new URL(request.url).origin, base);
          assert.equal(new URL(request.url).search, '');
          assert.equal(request.method, 'GET');
          assert.equal(request.body, null);
        }
        receipts.push({
          browser: name,
          version: browser.version(),
          readyMilliseconds: Math.round(ready),
          firstRunMilliseconds: firstCompilationAndExamplesMilliseconds,
          checks: [
            'format-save-compile ordering',
            'visible executed snapshot',
            'LawSpec/F#/TypeScript/JavaScript',
            'structured LawSpec quantifier layout',
            'Allman plugin',
            'idempotence',
            'syntax errors in LawSpec/F#/JS prevent execution',
            'failed storage prevents compilation',
            'formatting cancellation',
            'formatting timeout',
            'packaged GET requests only',
          ],
          errors,
        });
        console.log(`${name}: formatting checks passed`);
        continue;
      }
      assert.equal(await run(), 'Checks passed');
      await verifyProgress(page, course);
      await verifyTheme(page, output, name);
      if (process.env.LAWSPEC_LEARN_THEME_ONLY)
      {
        receipts.push({
          browser: name,
          version: browser.version(),
          checks: [
            'Auto follows system changes',
            'Light and Dark override system',
            'Monaco and generated output follow theme',
            'code and results preserved',
            'dark mobile layout',
          ],
          errors,
        });
        assert.deepEqual(errors, []);
        console.log(`${name}: theme checks passed`);
        continue;
      }
      await verifyCourseNavigation(page, course, output, name);
      await verifyLayout(page, output, name);
      if (process.env.LAWSPEC_LEARN_LAYOUT_ONLY)
      {
        receipts.push({
          browser: name,
          version: browser.version(),
          checks: [
            'opening prediction appears once',
            'desktop independent panes',
            'fixed step navigation',
            'new steps start at the heading',
            '720px laptop geometry',
            'compact read/code/course views',
            'read and results positions preserved',
            'editor model preserved',
            'language switches preserve view',
            'source links open code',
            'short-window Run toolbar',
          ],
          errors,
        });
        assert.deepEqual(errors, []);
        console.log(`${name}: layout checks passed`);
        continue;
      }
      const executionTimes = [];
      const selectLesson = async index =>
      {
        await page.locator('#lessons button[data-lesson]').nth(index).click();
        await page.waitForFunction(
          id =>
            new URLSearchParams(location.hash.slice(1)).get('lesson') === id,
          course.lessons[index].id,
        );
      };
      const selectScene = async (lesson, index) =>
      {
        await page.locator(`#stage button[data-stage="${index}"]`).click();
        await page.waitForFunction(
          id => new URLSearchParams(location.hash.slice(1)).get('scene') === id,
          lesson.stages[index].id,
        );
        assert.equal(
          await page.locator('#stage-title').textContent(),
          lesson.stages[index].title,
        );
      };
      for (let i = 0; i < course.lessons.length; i++)
      {
        const lesson = course.lessons[i];
        await selectLesson(i);
        await page.getByRole('tab', {name: 'F#', exact: true}).click();
        for (let step = 0; step < lesson.stages.length; step++)
        {
          const stage = lesson.stages[step];
          await selectScene(lesson, step);
          const focus =
            stage.focus === 'Solution'
              ? 'Solution.fs'
              : stage.focus === 'Tests'
                ? 'Tests.lawspec'
                : stage.focus;
          assert.equal(
            await page.locator('#current-file').textContent(),
            stage.editor === 'Tests' ? 'Tests.lawspec' : 'Solution.fs',
          );
          const actual = await page.evaluate(async () =>
          {
            const {monaco} = await import('./vendor/editor.mjs');
            return monaco.editor.getModels()[0].getValue();
          });
          assert.equal(
            actual,
            stage.projects.fsharp[
              stage.editor === 'Tests' ? 'Tests.lawspec' : 'Solution.fs'
            ],
            `${name}/${lesson.id}/${stage.id} editor source`,
          );
          await page.waitForFunction(
            expected =>
              document
                .querySelector('#story-code')
                .innerText.replace(/\u00a0/g, ' ')
                .trim() === expected.trim(),
            stage.projects.fsharp[focus],
          );
          const before = performance.now(),
            status = await run();
          executionTimes.push({
            lesson: lesson.id,
            scene: stage.id,
            language: 'fsharp',
            milliseconds: Math.round(performance.now() - before),
          });
          assert.equal(
            status,
            stage.run.expect === 'passed'
              ? 'Checks passed'
              : 'Check the failure',
            `${name}/${lesson.id}/${stage.id}: ${await page.locator('#message').textContent()}`,
          );
          assert.match(
            await page.locator('#teaching-feedback').textContent(),
            stage.run.expect === 'failed'
              ? /meant to reveal a failing check/
              : /matches the supplied step/,
          );
          assert.doesNotMatch(
            await page.locator('#teaching-feedback').textContent(),
            /differs from the supplied/,
          );
        }
        for (const language of ['fsharp', 'typescript', 'javascript'])
        {
          await page
            .getByRole('tab', {
              name:
                language === 'fsharp'
                  ? 'F#'
                  : language === 'typescript'
                    ? 'TypeScript'
                    : 'JavaScript',
              exact: true,
            })
            .click();
          await page.waitForFunction(
            lang =>
              new URLSearchParams(location.hash.slice(1)).get('language') ===
              lang,
            language,
          );
          await page.locator('#solution').click();
          assert.equal(
            await run(),
            'Checks passed',
            `${name}/${lesson.id}/${language} solution`,
          );
        }
        console.log(
          name,
          lesson.id,
          'all story steps and three solutions passed',
        );
      }
      // Revisit independent scene drafts: prose selection must load that scene's project.
      await selectLesson(0);
      await page.getByRole('tab', {name: 'F#', exact: true}).click();
      await selectScene(course.lessons[0], 0);
      await edit(
        'Solution.fs',
        'module Solution\nlet add (x: int) (y: int) : int = x + y\n',
      );
      assert.match(
        await page.locator('#story-state').textContent(),
        /Your edited version/,
      );
      await selectScene(course.lessons[0], 1);
      assert.equal(await run(), 'Check the failure');
      await selectScene(course.lessons[0], 0);
      assert.match(
        await page.locator('#story-state').textContent(),
        /Your edited version/,
      );
      await page.reload();
      await page.waitForFunction(
        () => document.documentElement.dataset.ready === 'true',
      );
      assert.match(
        await page.locator('#story-state').textContent(),
        /Your edited version/,
      );
      await page.locator('#load-stage').click();
      assert.equal(
        await page.locator('#story-state').textContent(),
        'Source for this step',
      );
      // A real scalar failure shrinks to 80 and creates executable regression code.
      await selectLesson(2);
      await selectScene(course.lessons[2], 1);
      assert.equal(await run(), 'Check the failure');
      assert.match(await page.locator('#outcomes').textContent(), /80/);
      await page.locator('#replay').click();
      await page.waitForFunction(
        () => document.querySelector('#cancel').disabled,
      );
      assert.match(await page.locator('#outcomes').textContent(), /80/);
      await page.locator('#regression').click();
      assert.equal(await run('examples'), 'Check the failure');
      assert.match(
        await page.locator('#outcomes').textContent(),
        /keep this counterexample/,
      );
      await page.locator('#solution').click();
      assert.equal(await run(), 'Checks passed');
      // The application failure is separate: replay a missing zero, then repair the implementation.
      await selectLesson(5);
      await selectScene(course.lessons[5], 1);
      assert.equal(await run(), 'Check the failure');
      assert.match(
        await page.locator('#outcomes').textContent(),
        /\[\s*0\s*\]/,
      );
      await page.locator('#regression').click();
      assert.equal(await run('examples'), 'Check the failure');
      await page.locator('#solution').click();
      assert.equal(await run(), 'Checks passed');
      await selectLesson(3);
      await page.getByRole('tab', {name: 'JavaScript', exact: true}).click();
      await edit(
        'Solution.js',
        'export function seats(rows) { while (true) {} }',
      );
      await page.setViewportSize({width: 320, height: 568});
      await page.locator('[data-view=code]').click();
      await page.locator('#run').click();
      await page.waitForTimeout(500);
      assert.equal(await page.locator('#cancel').isEnabled(), true);
      const busyGeometry = await page
        .locator('.workspace-toolbar')
        .evaluate(element => ({
          width: element.clientWidth,
          contentWidth: element.scrollWidth,
          bottom: element.getBoundingClientRect().bottom,
        }));
      assert.ok(
        busyGeometry.contentWidth <= busyGeometry.width,
        JSON.stringify(busyGeometry),
      );
      assert.ok(busyGeometry.bottom < 568);
      await page.screenshot({
        path: new URL(`${name}-busy-320.png`, output).pathname,
      });
      await page.locator('#cancel').click();
      await page.waitForFunction(
        () => document.querySelector('#cancel').disabled,
      );
      assert.equal(
        await page.locator('#result-status').textContent(),
        'Cancelled',
      );
      await page.setViewportSize({width: 1440, height: 1000});
      assert.equal(await run(), 'Execution incomplete');
      assert.match(await page.locator('#message').textContent(), /timed out/);
      await page.getByRole('tab', {name: 'TypeScript', exact: true}).click();
      await page.locator('#solution').click();
      assert.equal(await run(), 'Checks passed');
      await edit(
        'Solution.ts',
        'export function seats(rows: number): number { return "wrong"; }',
      );
      assert.match(
        await page.locator('#result-status').textContent(),
        /Edited/,
      );
      assert.equal(await run(), 'Checks could not run');
      await page.getByRole('tab', {name: 'JavaScript', exact: true}).click();
      await edit(
        'Solution.js',
        'export function seats(rows) { return rows * 4; }',
      );
      const isolated = await page.evaluate(async () =>
      {
        const {execute} = await import('./sandbox.mjs');
        return execute(
          `(async()=>{let blocked=0;try{await fetch('https://example.invalid/learner-source');}catch{blocked++;}try{importScripts('https://example.invalid/script.js');}catch{blocked++;}try{await new Promise(resolve=>{const socket=new WebSocket('wss://example.invalid/socket');socket.onerror=()=>{blocked++;resolve();};socket.onopen=resolve;});}catch{blocked++;}postMessage({result:{ok:blocked===3}});})();`,
        );
      });
      assert.equal(
        isolated.ok,
        true,
        'the execution sandbox denies network APIs independently of the lesson test language',
      );
      await page.locator('#progress-panel>summary').click();
      const downloadPromise = page.waitForEvent('download');
      await page.locator('#export').click();
      const download = await downloadPromise;
      const project = JSON.parse(await readFile(await download.path(), 'utf8'));
      assert.ok(project.drafts.length >= 20);
      assert.ok(project.codeLicenses[0].text.includes('Scott Wlaschin'));
      const chooserPromise = page.waitForEvent('filechooser');
      await page.locator('#restore').click();
      const chooser = await chooserPromise;
      await chooser.setFiles({
        name: 'progress.json',
        mimeType: 'application/json',
        buffer: Buffer.from(JSON.stringify(project)),
      });
      await page.waitForFunction(() =>
        document.querySelector('#message').textContent.includes('restored'),
      );
      assert.match(
        await page.locator('#result-status').textContent(),
        /no current run/,
      );
      await page.screenshot({
        path: new URL(`${name}.png`, output).pathname,
        fullPage: true,
      });
      await page.setViewportSize({width: 390, height: 844});
      await page.screenshot({
        path: new URL(`${name}-mobile.png`, output).pathname,
        fullPage: true,
      });
      assert.equal(
        await page.evaluate(
          () => document.documentElement.scrollWidth <= innerWidth,
        ),
        true,
        'mobile overflow',
      );
      assert.deepEqual(errors, [], `${name} uncaught errors`);
      await page.setViewportSize({width: 1440, height: 1000});
      await page.route('**/compile-worker.mjs', route =>
        route.fulfill({
          contentType: 'text/javascript',
          body: 'self.onmessage=()=>{};',
        }),
      );
      await page.reload();
      await page.waitForFunction(
        () => document.documentElement.dataset.ready === 'true',
      );
      await page.clock.install();
      await page.locator('#run-options>summary').click();
      await page.locator('#examples').click();
      await page.waitForFunction(
        () =>
          document.querySelector('#result-status').textContent === 'Compiling',
        undefined,
        {timeout: 120000},
      );
      await page.clock.fastForward(120001);
      await page.waitForFunction(
        () => document.querySelector('#cancel').disabled,
      );
      assert.equal(
        await page.locator('#result-status').textContent(),
        'Execution incomplete',
      );
      assert.match(
        await page.locator('#message').textContent(),
        /Compilation timed out/,
      );
      const network = requests.filter(row => /^https?:/.test(row.url));
      for (const request of network)
      {
        const url = new URL(request.url);
        assert.equal(url.origin, base);
        assert.equal(url.search, '');
        assert.equal(request.method, 'GET');
        assert.equal(request.body, null);
      }
      receipts.push({
        browser: name,
        version: browser.version(),
        readyMilliseconds: Math.round(ready),
        firstCompilationAndExamplesMilliseconds,
        executionTimes,
        repeatGeneration,
        networkRequests: network.length,
        sourceUploads: 0,
        checks: [
          'every supplied story step in F#',
          'six solutions in three languages',
          'scene code/prose alignment',
          'independent scene drafts',
          'LawSpec tokenization',
          'requested fonts loaded',
          'Auto/Light/Dark and persistence',
          'Monaco and generated output themes',
          'grouped course outline and nested active steps',
          'secondary progress backup/restore',
          'preview and future content inside course information',
          'compact language and file tabs',
          'keyboard file tabs',
          'shrinking and replay',
          'regression',
          'reload',
          'language drafts',
          'cancellation',
          'execution timeout',
          'compilation timeout',
          'type errors',
          'network denial',
          'export/import',
          'mobile layout',
          'viewport-based workbench',
          'independent pane scrolling',
          'compact view restoration',
          'step-specific prediction',
        ],
      });
      console.log(`${name}: passed`);
    }
    finally
    {
      await context.close();
      await browser.close();
    }
  }
}
finally
{
  await new Promise(resolve => server.close(resolve));
  await writeFile(
    new URL(
      process.env.LAWSPEC_LEARN_FORMATTING_ONLY
        ? 'formatting.json'
        : process.env.LAWSPEC_LEARN_NOVICE_ONLY
          ? 'novice.json'
          : process.env.LAWSPEC_LEARN_TABS_ONLY
            ? 'tabs.json'
            : process.env.LAWSPEC_LEARN_HARNESS_ONLY
              ? 'harness.json'
              : process.env.LAWSPEC_LEARN_PROGRESS_ONLY
                ? 'progress.json'
                : process.env.LAWSPEC_LEARN_LAYOUT_ONLY
                  ? 'layout.json'
                  : process.env.LAWSPEC_LEARN_THEME_ONLY
                    ? 'themes.json'
                    : 'browsers.json',
      output,
    ),
    JSON.stringify(receipts, null, 2) + '\n',
  );
}
