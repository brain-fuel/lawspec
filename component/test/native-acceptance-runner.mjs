// Generated from templates/component/test/native-acceptance-runner.mjs by lawspec-dev generate. Do not edit.
// ref:DEC-node-native-acceptance-bundle
// Runs the shipped compiler acceptance on a native Node host without build tools.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createReadStream} from 'node:fs';
import {readFile, mkdtemp, writeFile, rm} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import path from 'node:path';
/** Locates the self-contained acceptance directory. ref:REQ-host-sdk-runtime-boundary */
const root = import.meta.dirname;
/** Selects only the executing host's optional packages. ref:REQ-host-sdk-runtime-boundary */
const platform = `${process.platform}-${process.arch}`;
assert.ok([22, 24, 26].includes(Number(process.versions.node.split('.')[0])));
/** Reads the builder's copied receipt snapshots. ref:REQ-host-sdk-runtime-boundary */
const read = async name =>
  JSON.parse(await readFile(path.join(root, name), 'utf8'));
/** Pins the independent host runtime and platform helpers. ref:REQ-host-sdk-runtime-boundary */
const sdk = await read('component/sdk-packages.json');
/** Pins application-owned native code separately from its host. ref:REQ-host-sdk-runtime-boundary */
const natives = await read('component/native-packages.json');
/** Identifies the application archive under test. ref:REQ-host-sdk-runtime-boundary */
const application = await read('component/vendor/application-package.json');
assert.ok(
  sdk.platforms[platform] && natives[platform],
  'unsupported acceptance host',
);
/** Resolves the content-addressed local SDK archive names. ref:REQ-host-sdk-runtime-boundary */
const sdkRecord = entry => ({
  ...entry,
  file: entry.file.replace('.tgz', `-${entry.shasum.slice(0, 12)}.tgz`),
});
/** Requires all four packages used by this consumer installation. ref:REQ-host-sdk-runtime-boundary */
const records = [
  sdkRecord(sdk.runtime),
  sdkRecord(sdk.platforms[platform]),
  natives[platform],
  {...application, file: application.filename},
];
/** Admits archive paths only after their integrity checks pass. ref:REQ-host-sdk-runtime-boundary */
const files = [];
for (const entry of records)
{
  const file = path.join(root, 'component/vendor', entry.file);
  const hash = createHash('sha512');
  for await (const chunk of createReadStream(file)) hash.update(chunk);
  assert.equal('sha512-' + hash.digest('base64'), entry.integrity, entry.file);
  files.push(file);
}
console.log(
  JSON.stringify({
    platform,
    node: process.version,
    verifiedArchives: records.map(({file, integrity}) => ({file, integrity})),
  }),
);
/** Isolates npm cache population from the offline acceptance installation. ref:REQ-host-sdk-runtime-boundary */
const setup = await mkdtemp(path.join(tmpdir(), 'lawspec-native-cache-'));
try
{
  // Populate only npm's dependency cache before the offline, toolchain-free test.
  await writeFile(path.join(setup, 'package.json'), '{"private":true}');
  execFileSync(
    'npm',
    ['install', '--ignore-scripts', '--no-audit', '--no-fund', ...files],
    {cwd: setup, stdio: 'inherit', timeout: 300000},
  );
}
finally
{
  await rm(setup, {recursive: true, force: true});
}
execFileSync(process.execPath, ['--test', 'component/test/package.test.mjs'], {
  cwd: root,
  env: {
    ...process.env,
    LAWSPEC_TEST_PACKAGE: path.join(
      root,
      'component/vendor/application-package.json',
    ),
  },
  stdio: 'inherit',
  timeout: 1620000,
});
