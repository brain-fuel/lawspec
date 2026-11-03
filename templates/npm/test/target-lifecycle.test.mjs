import assert from 'node:assert/strict';
import {test} from 'node:test';
import {spawnSync} from 'node:child_process';
import {mkdtemp, mkdir, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {configEDN} from './manifest-fixtures.mjs';

const cli = new URL('../bin/lawspec.mjs', import.meta.url).pathname;
const run = (root, ...args) =>
  spawnSync(process.execPath, [cli, ...args], {
    cwd: root,
    encoding: 'utf8',
    timeout: 30000,
  });

for (const language of ['go', 'javascript', 'yaml', 'hcl'])
{
  test(`${language}: init repairs a declared missing target and preserves its manifest`, async t =>
  {
    const root = await mkdtemp(path.join(tmpdir(), 'lawspec-target-repair-'));
    t.after(() => rm(root, {recursive: true, force: true}));
    const target = `output/${language}`;
    const manifest =
      '; Keep this authored comment.\n' +
      configEDN({
        manifestVersion: 1,
        languageProfile: '1.0-rc.2',
        verification: {layers: []},
        sources: ['laws'],
        targets: [
          {
            language,
            root: target,
            sourceDir: 'generated',
            ...(language === 'go' ? {testDir: 'generated'} : {}),
          },
        ],
      });
    await writeFile(path.join(root, 'lawspec.edn'), manifest);
    await mkdir(path.join(root, 'laws'));
    await writeFile(
      path.join(root, 'laws', 'settings.lawspec'),
      'unit settings\nfunction port (unused :: Unit) -> UInt16 is 8080 end function\nend unit\n',
    );
    const repaired = run(root, 'init', '--target', language);
    assert.equal(repaired.status, 0, repaired.stdout + repaired.stderr);
    assert.equal(
      await readFile(path.join(root, 'lawspec.edn'), 'utf8'),
      manifest,
    );
    const again = run(root, 'init', '--target', language);
    assert.equal(again.status, 0, again.stdout + again.stderr);
    assert.equal(
      await readFile(path.join(root, 'lawspec.edn'), 'utf8'),
      manifest,
    );
    if (language === 'go' || language === 'javascript')
    {
      const name = language === 'go' ? 'go.mod' : 'package.json';
      const file = path.join(root, target, name);
      const original = await readFile(file, 'utf8');
      await writeFile(file, original + '\n');
      const preserved = run(root, 'init', '--target', language);
      assert.equal(preserved.status, 0, preserved.stdout + preserved.stderr);
      assert.equal(await readFile(file, 'utf8'), original + '\n');
    }
    if (language === 'yaml' || language === 'hcl')
    {
      const generated = run(root, 'generate');
      assert.equal(generated.status, 0, generated.stdout + generated.stderr);
    }
  });
}

test('new starter specifications are editable and ambiguous target roots require a choice', async t =>
{
  const root = await mkdtemp(path.join(tmpdir(), 'lawspec-starter-ownership-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  const initialized = run(root, 'init', '--target', 'go');
  assert.equal(initialized.status, 0, initialized.stdout + initialized.stderr);
  const starter = await readFile(
    path.join(root, 'laws', 'atoi_codec.lawspec'),
    'utf8',
  );
  assert.doesNotMatch(starter, /Generated.*Do not edit/);
  assert.match(starter, /unit example.codec/);
  await writeFile(
    path.join(root, 'lawspec.edn'),
    configEDN({
      manifestVersion: 1,
      languageProfile: '1.0-rc.2',
      sources: ['laws'],
      targets: [
        {language: 'go', root: 'first'},
        {language: 'go', root: 'second'},
      ],
    }),
  );
  const ambiguous = run(root, 'init', '--target', 'go');
  assert.notEqual(ambiguous.status, 0);
  assert.match(ambiguous.stderr, /Several go targets.*--project/);
  const selected = run(root, 'init', '--target', 'go', '--project', 'second');
  assert.equal(selected.status, 0, selected.stdout + selected.stderr);
  assert.match(
    await readFile(path.join(root, 'second', 'go.mod'), 'utf8'),
    /module /,
  );
});
