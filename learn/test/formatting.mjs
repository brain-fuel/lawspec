/** @file Verify real format/save/compile ordering and visible failure behavior. ref:REQ-learn-format-before-run */
import assert from 'node:assert/strict';

export async function observeWorkers(page)
{
  await page.addInitScript(() =>
  {
    const NativeWorker = window.Worker;
    window.__learnWorkerTrace = [];
    window.Worker = class extends NativeWorker
    {
      constructor(address, options)
      {
        super(address, options);
        this.phase = String(address).includes('format-worker')
          ? 'format'
          : 'compile';
        this.addEventListener('message', ({data}) =>
        {
          if (this.phase === 'format' && !data.progress)
          {
            window.__learnWorkerTrace.push({
              phase: 'formatted',
              files: data.result?.files,
              error: data.error,
            });
          }
        });
      }
      postMessage(request, ...transfer)
      {
        window.__learnWorkerTrace.push({
          phase: this.phase,
          files: structuredClone(request.files),
        });
        return super.postMessage(request, ...transfer);
      }
    };
  });
}

export async function verifyFormatting(page)
{
  const edit = async (file, text) =>
  {
    await page.locator(`#files [data-file="${file}"]`).click();
    await page.evaluate(async source =>
    {
      const {monaco} = await import('./vendor/editor.mjs');
      monaco.editor.getModels()[0].setValue(source);
    }, text);
    await page.waitForFunction(
      () =>
        document.querySelector('#save-status').textContent ===
        'Saved on device',
    );
  };
  const read = () =>
    page.evaluate(async () =>
    {
      const {monaco} = await import('./vendor/editor.mjs');
      return monaco.editor.getModels()[0].getValue();
    });
  const execute = async () =>
  {
    await page.evaluate(() => (window.__learnWorkerTrace = []));
    await page.locator('#run').click();
    await page.waitForFunction(
      () => document.querySelector('#cancel').disabled,
      undefined,
      {timeout: 120000},
    );
    return page.evaluate(() => window.__learnWorkerTrace);
  };
  for (const [language, label, extension, source] of [
    ['fsharp', 'F#', 'fs', 'module Solution\nlet add(x:int)(y:int):int=x+y\n'],
    [
      'typescript',
      'TypeScript',
      'ts',
      'export function add(x:number,y:number):number{if(x===0){return y;}else{return x+y;}}',
    ],
    [
      'javascript',
      'JavaScript',
      'js',
      'export function add(x,y){if(x===0){return y;}else{return x+y;}}',
    ],
  ])
  {
    await page.getByRole('tab', {name: label, exact: true}).click();
    await page.waitForFunction(
      value => location.hash.includes('language=' + value),
      language,
    );
    await edit(
      'Tests.lawspec',
      'unit learn.addition\nadd :: Int32 -> Int32 -> Int32\nlaw onePlusTwo is definition: add 1 2 = 3 end definition end law\nlaw "|adding zero keeps the value| is\n  definition:\n    for all (value :: Int32 where value >= 0 and value <= 40) => add value 0 = value\n      + 0 end for all\n  end definition\nend law\nend unit\n',
    );
    await edit(
      'Harness.lawspec',
      'harness learn.addition.testing for learn.addition is end harness\n',
    );
    await edit('Solution.' + extension, source);
    const trace = await execute();
    assert.equal(
      await page.locator('#result-status').textContent(),
      'Checks passed',
      language + ': ' + (await page.locator('#diagnostics').textContent()),
    );
    assert.deepEqual(
      trace.map(row => row.phase),
      ['format', 'formatted', 'compile'],
    );
    assert.deepEqual(
      trace[2].files,
      trace[1].files,
      'compile receives exactly the successful format snapshot',
    );
    assert.match(
      trace[2].files['Tests.lawspec'],
      /    for all \(value :: Int32 where value >= 0 and value <= 40\) =>\n      add value 0 = value \+ 0\n    end for all\n/,
      'Run gives the quantified claim its own indented line',
    );
    assert.notEqual(trace[2].files['Solution.' + extension], source);
    assert.equal(
      await read(),
      trace[2].files['Solution.' + extension],
      'the executed source is visible in Monaco',
    );
    const stored = await page.evaluate(async () =>
    {
      const {openStore, draftKey} = await import('./store.mjs');
      const params = new URLSearchParams(location.hash.slice(1));
      return (await openStore()).get(
        draftKey(
          params.get('lesson'),
          params.get('track'),
          params.get('language'),
          params.get('scene'),
        ),
      );
    });
    assert.deepEqual(
      stored.files,
      trace[2].files,
      'formatting is saved before compilation',
    );
    const repeated = await execute();
    assert.deepEqual(
      repeated[2].files,
      trace[2].files,
      'formatting is idempotent',
    );
    if (extension !== 'fs') assert.match(await read(), /\n\{\n/);
    await page.locator('#load-stage').click();
  }
  await edit('Solution.js', 'export function add( {');
  const before = await read(),
    failure = await execute();
  assert.equal(
    await page.locator('#result-status').textContent(),
    'Formatting failed',
  );
  assert.equal(
    failure.some(row => row.phase === 'compile'),
    false,
  );
  assert.equal(
    await read(),
    before,
    'formatter failure preserves the complete draft',
  );
  assert.match(
    await page.locator('#diagnostics').textContent(),
    /LEARN_FORMAT_SYNTAX/,
  );
  await page.locator('#load-stage').click();
  await page.getByRole('tab', {name: 'F#', exact: true}).click();
  await page.waitForFunction(() => location.hash.includes('language=fsharp'));
  await page.locator('#load-stage').click();
  for (const [file, source] of [
    ['Solution.fs', 'module Solution\nlet add ='],
    ['Tests.lawspec', 'unit learn.addition\nlaw'],
  ])
  {
    await edit(file, source);
    const failure = await execute();
    assert.equal(
      await page.locator('#result-status').textContent(),
      'Formatting failed',
    );
    assert.equal(
      failure.some(row => row.phase === 'compile'),
      false,
    );
    assert.equal(await read(), source);
    await page.locator('#load-stage').click();
  }
  await page.evaluate(() =>
  {
    window.__originalPut = IDBObjectStore.prototype.put;
    IDBObjectStore.prototype.put = function ()
    {
      throw new DOMException(
        'Storage unavailable for test',
        'QuotaExceededError',
      );
    };
  });
  try
  {
    const failedSave = await execute();
    assert.equal(
      await page.locator('#result-status').textContent(),
      'Execution incomplete',
    );
    assert.equal(
      failedSave.some(row => row.phase === 'compile'),
      false,
      'failed persistence prevents execution',
    );
    assert.match(
      await page.locator('#message').textContent(),
      /Storage unavailable/,
    );
  }
  finally
  {
    await page.evaluate(() =>
    {
      IDBObjectStore.prototype.put = window.__originalPut;
    });
  }
  const stalled = await page.context().newPage();
  await observeWorkers(stalled);
  // A stalled formatter must be cancellable and bounded independently of compilation.
  await stalled.route('**/format-worker.mjs', route =>
    route.fulfill({
      contentType: 'text/javascript',
      body: 'self.onmessage=()=>{};',
    }),
  );
  await stalled.goto(page.url());
  await stalled.waitForFunction(
    () => document.documentElement.dataset.ready === 'true',
  );
  await stalled.locator('#run').click();
  await stalled.waitForFunction(
    () => document.querySelector('#result-status').textContent === 'Formatting',
  );
  await stalled.locator('#cancel').click();
  await stalled.waitForFunction(
    () => document.querySelector('#cancel').disabled,
  );
  assert.equal(
    await stalled.locator('#result-status').textContent(),
    'Cancelled',
  );
  assert.equal(
    (await stalled.evaluate(() => window.__learnWorkerTrace)).some(
      row => row.phase === 'compile',
    ),
    false,
  );
  await stalled.clock.install();
  await stalled.locator('#run').click();
  await stalled.clock.fastForward(120001);
  await stalled.waitForFunction(
    () => document.querySelector('#cancel').disabled,
  );
  assert.equal(
    await stalled.locator('#result-status').textContent(),
    'Execution incomplete',
  );
  assert.match(
    await stalled.locator('#message').textContent(),
    /Formatting timed out/,
  );
  await stalled.close();
  assert.equal(
    await page.locator('#story-state').textContent(),
    'Source for this step',
  );
}
