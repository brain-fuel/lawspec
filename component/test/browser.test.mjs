// Generated from templates/component/test/browser.test.mjs by lawspec-dev generate. Do not edit.
// Browser application parity through the packed SDK. ref:DEC-host-sdk-independent-consumer
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createServer} from 'node:http';
import {readFile, mkdtemp, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {createRequire} from 'node:module';
/** Resolves the pinned browser engines used for real component acceptance. ref:REQ-host-sdk-runtime-boundary */
const require = createRequire(
  new URL('../../learn/package.json', import.meta.url),
);
/** Exercises every declared browser engine with the same typed application. ref:REQ-host-sdk-runtime-boundary */
const {chromium, firefox, webkit} = require('@playwright/test');
/** Restricts the test server to the consuming application assets. ref:REQ-host-sdk-runtime-boundary */
const root = fileURLToPath(new URL('../', import.meta.url));
for (const [name, engine] of Object.entries({
  chromium,
  firefox,
  webkit,
  'chromium-isolated': chromium,
}))
{
  test(`LawSpec component in ${name}`, {timeout: 120000}, async t =>
  {
    const server = createServer(async (req, res) =>
    {
      try
      {
        const pathname = new URL(req.url, 'http://localhost').pathname;
        const file = path.resolve(root, '.' + pathname);
        if (file !== root.slice(0, -1) && !file.startsWith(root))
        {
          res.writeHead(403).end();
          return;
        }
        res.setHeader(
          'Content-Type',
          file.endsWith('.wasm')
            ? 'application/wasm'
            : /\.(js|mjs)$/.test(file)
              ? 'text/javascript'
              : file.endsWith('.json')
                ? 'application/json'
                : 'text/html',
        );
        res.setHeader(
          'Content-Security-Policy',
          "default-src 'self'; script-src 'self' blob: 'wasm-unsafe-eval'; worker-src 'self'; connect-src 'self'",
        );
        if (name.endsWith('isolated'))
        {
          res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
          res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
        }
        res.end(
          pathname === '/'
            ? '<!doctype html><title>LawSpec component</title>'
            : await readFile(file),
        );
      }
      catch
      {
        res.writeHead(404).end();
      }
    });
    await new Promise(r => server.listen(0, '127.0.0.1', r));
    const profile =
      name === 'webkit'
        ? await mkdtemp(path.join(tmpdir(), 'lawspec-webkit-'))
        : undefined;
    const browser = profile
      ? await engine.launchPersistentContext(profile, {headless: true})
      : await engine.launch({headless: true});
    t.after(async () =>
    {
      await browser.close();
      server.closeAllConnections();
      await new Promise(r => server.close(r));
      if (profile) await rm(profile, {recursive: true, force: true});
    });
    const page = await browser.newPage();
    const origin = `http://127.0.0.1:${server.address().port}`;
    await page.goto(origin);
    const result = await page.evaluate(async isolated =>
    {
      const {createApplication} = await import('/assets/browser.mjs');
      const host = await createApplication({
        deployment: isolated ? 'isolated' : 'standard',
      });
      try
      {
        const input = {
          schemaVersion: 5,
          method: 'check',
          languageProfile: '1.0-rc.2',
          verification: {layers: []},
          sources: [
            {
              path: 'example.lawspec',
              content:
                'unit example\nfunction id (x :: Int32) -> Int32 is x end function\nend unit\n',
            },
          ],
        };
        const catalog = await host.prelude({tag: 'matching', val: 'length'});
        const versions = await host.selectVersions({
          range: '^1.0.0',
          versions: ['2.0.0', '1.2.0'],
        });
        const typedFormatted = await host.format({
          sources: input.sources,
        });
        const checked = JSON.parse(
          await host.invoke('dispatch', [JSON.stringify(input)]),
        );
        const formatted = JSON.parse(
          await host.invoke('dispatch', [
            JSON.stringify({...input, method: 'format'}),
          ]),
        );
        const rejected = JSON.parse(
          await host.invoke('dispatch', [
            JSON.stringify({
              ...input,
              sources: [
                {
                  path: 'bad.lawspec',
                  content:
                    'unit bad\nfunction f (x :: Rational) -> Rational is x / 0 end function\nend unit\n',
                },
              ],
            }),
          ]),
        );
        let denied;
        try
        {
          await host.invoke('exercise', [
            'absent',
            {tag: 'get-value', val: 'secret'},
          ]);
        }
        catch (e)
        {
          denied = e.code;
        }
        return {
          catalog,
          versions,
          typedFormatted,
          checked: checked.diagnostics,
          formatted: formatted.formattedSources,
          rejected: rejected.diagnostics,
          denied,
        };
      }
      finally
      {
        host.close();
      }
    }, name.endsWith('isolated'));
    assert.equal(result.catalog.tag, 'catalog');
    assert.ok(result.catalog.val.entries.length);
    assert.deepEqual(result.versions, {problems: [], versions: ['1.2.0']});
    assert.deepEqual(result.typedFormatted.diagnostics, []);
    assert.deepEqual(result.typedFormatted.formattedSources, result.formatted);
    assert.deepEqual(result.checked, []);
    assert.ok(result.formatted.length);
    assert.ok(result.rejected.length);
    assert.equal(result.denied, 'denied');
    await page.goto(origin + '/examples/plain-page.html');
    await page.locator('#format').click();
    await page.waitForFunction(() =>
      document
        .querySelector('#status')
        .textContent.includes('Formatted locally'),
    );
  });
}
