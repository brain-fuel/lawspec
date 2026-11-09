// Generated from templates/component/test/acceptance-bundle.test.mjs by lawspec-dev generate. Do not edit.
// The Haskell builder transports exact archives without claiming platform acceptance.
// ref:DEC-node-native-acceptance-bundle
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync, execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createHash} from 'node:crypto';
import {
  mkdtemp,
  mkdir,
  writeFile,
  readFile,
  readdir,
  symlink,
  rm,
} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';

/** Uses the built Haskell bootstrap for application packaging. ref:REQ-host-sdk-runtime-boundary */
const binary = path.join(
  execFileSync('stack', ['--no-terminal', 'path', '--local-install-root'], {
    encoding: 'utf8',
  }).trim(),
  'bin/lawspec-dev',
);
/** Captures subprocess failures without masking their exit status. ref:REQ-host-sdk-runtime-boundary */
const exec = promisify(execFile);

/** Supplies small distinct opaque archives; this test verifies assembly, not execution. ref:REQ-host-sdk-runtime-boundary */
async function fixture(t)
{
  const root = await mkdtemp(
    path.join(tmpdir(), 'lawspec-acceptance-builder-'),
  );
  t.after(() => rm(root, {recursive: true, force: true}));
  await mkdir(path.join(root, 'component/vendor'), {recursive: true});
  await mkdir(path.join(root, 'component/test'));
  await mkdir(path.join(root, 'component/acceptance'));
  const archive = async (name, sdk = false) =>
  {
    const bytes = Buffer.from(`archive fixture ${name}`);
    const shasum = createHash('sha1').update(bytes).digest('hex');
    const file = `${name}.tgz`;
    const stored = sdk ? `${name}-${shasum.slice(0, 12)}.tgz` : file;
    await writeFile(path.join(root, 'component/vendor', stored), bytes);
    return {
      file,
      stored,
      shasum,
      integrity:
        'sha512-' + createHash('sha512').update(bytes).digest('base64'),
    };
  };
  const sdk = {runtime: await archive('sdk-runtime', true), platforms: {}};
  const natives = {};
  for (const platform of [
    'darwin-arm64',
    'darwin-x64',
    'linux-arm64',
    'linux-x64',
  ])
  {
    sdk.platforms[platform] = await archive(`sdk-${platform}`, true);
    natives[platform] = await archive(`native-${platform}`);
  }
  const app = await archive('application');
  const receipt = {filename: app.file, integrity: app.integrity};
  const save = async () =>
  {
    await writeFile(
      path.join(root, 'component/sdk-packages.json'),
      JSON.stringify(sdk),
    );
    await writeFile(
      path.join(root, 'component/native-packages.json'),
      JSON.stringify(natives),
    );
    await writeFile(
      path.join(root, 'component/vendor/application-package.json'),
      JSON.stringify(receipt),
    );
  };
  await save();
  for (const file of [
    'component/test/package.test.mjs',
    'component/test/native-acceptance-runner.mjs',
    'component/acceptance/README.txt',
  ])
    await writeFile(path.join(root, file), `fixture ${file}`);
  const run = (output = 'bundle') =>
    exec(
      binary,
      [
        'native-acceptance',
        '--package',
        'component/vendor/application-package.json',
        '--out',
        output,
      ],
      {cwd: root},
    );
  const absent = async () =>
  {
    for (const file of ['bundle', 'bundle.staging'])
      await assert.rejects(readdir(path.join(root, file)), {code: 'ENOENT'});
  };
  return {root, sdk, natives, receipt, run, save, absent};
}

test('acceptance bundle preserves all ten verified archives and refuses existing output', async t =>
{
  const f = await fixture(t);
  await f.run('bundle/');
  const files = await readdir(path.join(f.root, 'bundle/component/vendor'));
  assert.equal(files.filter(file => file.endsWith('.tgz')).length, 10);
  for (const file of files.filter(file => file.endsWith('.tgz')))
    assert.deepEqual(
      await readFile(path.join(f.root, 'bundle/component/vendor', file)),
      await readFile(path.join(f.root, 'component/vendor', file)),
    );
  await assert.rejects(f.run(), /already exists/);
  assert.equal(
    (await readdir(path.join(f.root, 'bundle/component/vendor'))).length,
    11,
  );
});

test('acceptance bundle rejects corrupt archives and cleans partial staging', async t =>
{
  const f = await fixture(t);
  await writeFile(
    path.join(f.root, 'component/vendor', f.receipt.filename),
    'corrupted',
  );
  await assert.rejects(f.run(), /integrity mismatch/);
  await f.absent();
});

test('acceptance bundle rejects path traversal and incomplete platform receipts before writing', async t =>
{
  const f = await fixture(t);
  f.receipt.filename = '../escape.tgz';
  await f.save();
  await assert.rejects(f.run(), /Invalid acceptance archive filename/);
  await f.absent();
  f.receipt.filename = 'application.tgz';
  delete f.sdk.platforms['linux-x64'];
  await f.save();
  await assert.rejects(f.run(), /linux-x64/);
  await f.absent();
});

test('acceptance bundle rejects symlink archives and preserves an existing staging directory', async t =>
{
  const f = await fixture(t);
  const archive = path.join(f.root, 'component/vendor', f.receipt.filename);
  await rm(archive);
  await symlink(
    'sdk-runtime-' + f.sdk.runtime.shasum.slice(0, 12) + '.tgz',
    archive,
  );
  await assert.rejects(f.run(), /must not be a symlink/);
  await f.absent();
  await mkdir(path.join(f.root, 'bundle.staging'));
  await writeFile(path.join(f.root, 'bundle.staging/owned.txt'), 'preserve');
  await assert.rejects(f.run(), /already exists/);
  assert.equal(
    await readFile(path.join(f.root, 'bundle.staging/owned.txt'), 'utf8'),
    'preserve',
  );
});
