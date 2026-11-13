import {configEDN} from './manifest-fixtures.mjs';
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, readFile, writeFile, rm, readdir} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {supported, doctor} from '../doctor.mjs';
const exec = promisify(execFile);
test('compatibility profiles enforce Java 25 and Python 3.13 floors', () =>
{
  assert.equal(supported('java', 'java', '24.0.2'), false);
  assert.equal(supported('java', 'java', '25.0.4'), true);
  assert.equal(supported('python', 'python', '3.12.12'), false);
  assert.equal(supported('python', 'python', '3.13.15'), true);
  assert.equal(supported('python', 'python', '3.13.0rc1'), false);
  assert.equal(supported('python', 'hypothesis', '6.0.0'), false);
});
test('incompatible or unverifiable environments prevent generation writes', async t =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-doctor-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  const executable = path.join(root, 'python');
  const config = {
    manifestVersion: 1,
    languageProfile: '1.0-rc.2',
    verification: {layers: []},
    sources: ['codec.lawspec'],
    targets: [{language: 'python', root: '.', python: executable}],
  };
  await writeFile(path.join(root, 'lawspec.edn'), configEDN(config));
  await writeFile(
    path.join(root, 'codec.lawspec'),
    await readFile(new URL('../starter-rc1.lawspec', import.meta.url), 'utf8'),
  );
  for (const version of ['3.12.15', 'unknown'])
  {
    const report = {
      python: version,
      pytest: '8.4.2',
      hypothesis: '6.135.26',
      config: {pythonpath: ['src'], testpaths: ['tests']},
    };
    await writeFile(
      executable,
      `#!${process.execPath}\nconsole.log(${JSON.stringify(JSON.stringify(report))});\n`,
      {mode: 0o755},
    );
    const before = (await readdir(root)).sort();
    assert.equal((await doctor(config.targets[0], root)).ok, false);
    await assert.rejects(
      exec(
        process.execPath,
        [new URL('../bin/lawspec.mjs', import.meta.url).pathname, 'generate'],
        {cwd: root},
      ),
      e => e.code === 1 && /python/.test(e.stdout + e.stderr),
    );
    assert.deepEqual((await readdir(root)).sort(), before);
    assert.equal(
      await readFile(path.join(root, 'lawspec.edn'), 'utf8'),
      configEDN(config),
    );
  }
});

test('Rapid accepts both stable baselines and rejects unsupported versions', () =>
{
  for (const version of ['1.2.0', 'v1.3.0', '1.3.1'])
    assert.equal(supported('go', 'rapid', version), true);
  for (const version of ['1.1.0', '1.4.0', '1.3.0-rc.1', 'local', ''])
    assert.equal(supported('go', 'rapid', version), false);
});

test('Go doctor applies the shared Rapid range to resolved modules', async t =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-go-doctor-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  await writeFile(
    path.join(root, 'go'),
    `#!${process.execPath}
if (process.argv[2] === 'version') console.log('go version go1.25.0 darwin/arm64');
else if (process.argv.includes('-json')) console.log(JSON.stringify({
  Version: process.env.RAPID_TEST_VERSION,
  ...(process.env.RAPID_TEST_REPLACE ? {Replace: {Dir: '/local'}} : {}),
}));
`,
    {mode: 0o755},
  );
  const module = new URL('../doctor.mjs', import.meta.url).href;
  const code = `import {doctor} from ${JSON.stringify(module)}; console.log(JSON.stringify(await doctor({language:'go'},process.cwd())));`;
  for (const [version, replacement, expected] of [
    ['v1.2.0', '', true],
    ['v1.3.0', '', true],
    ['v1.3.0', 'local', false],
    ['v1.4.0', '', false],
    ['v1.3.0-rc.1', '', false],
  ])
  {
    const {stdout} = await exec(
      process.execPath,
      ['--input-type=module', '-e', code],
      {
        cwd: root,
        env: {
          ...process.env,
          PATH: root + path.delimiter + process.env.PATH,
          RAPID_TEST_VERSION: version,
          RAPID_TEST_REPLACE: replacement,
        },
      },
    );
    assert.equal(JSON.parse(stdout).ok, expected, `${version} ${replacement}`);
  }
});
test('haskell: a project never built is told to build it, before Stack runs', async t =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-doctor-haskell-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  await writeFile(path.join(root, 'package.yaml'), 'name: example\n');
  const report = await doctor({language: 'haskell'}, root);
  assert.equal(report.ok, false);
  assert.match(JSON.stringify(report), /has no \.cabal file yet/);
  assert.match(JSON.stringify(report), /stack build --test --no-run-tests/);
});
