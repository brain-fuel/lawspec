// Application packaging consumes only the installed, integrity-pinned SDK.
// ref:DEC-node-precompiled-components
import {packageNativeArtifacts, nativeTargets} from 'wasm-platform-kit-build';
import {
  readFile,
  writeFile,
  mkdir,
  copyFile,
  rm,
  rename,
} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const directory = path.join(root, 'assets');
const packageDirectory = path.join(root, 'native-packages');
const application = JSON.parse(
  await readFile(path.join(root, '../npm/package.json'), 'utf8'),
);
const entries = JSON.parse(
  await readFile(path.join(directory, 'native-artifacts.json'), 'utf8'),
);
const artifacts = new Map(
  Object.entries(entries).map(([platform, registration]) => [
    platform,
    {
      platform,
      registration,
      file: registration.file
        ? path.join(directory, registration.file)
        : path.join(packageDirectory, platform, 'component.cwasm'),
    },
  ]),
);
const args = process.argv.slice(2);
const requireAll = args.includes('--require-all');
for (const input of args.filter(arg => arg !== '--require-all'))
{
  const receiptDirectory = path.resolve(input);
  const registration = JSON.parse(
    await readFile(path.join(receiptDirectory, 'registration.json'), 'utf8'),
  );
  const platform = Object.keys(nativeTargets).find(
    key => nativeTargets[key] === registration.target,
  );
  if (!platform) throw new Error(`unsupported native receipt: ${input}`);
  artifacts.set(platform, {
    platform,
    registration,
    file: path.join(receiptDirectory, 'component.cwasm'),
  });
}
if (
  requireAll &&
  Object.keys(nativeTargets).some(platform => !artifacts.has(platform))
)
  throw new Error('all macOS/Linux x64/ARM64 native builds are required');
await packageNativeArtifacts({
  directory,
  artifacts: [...artifacts.values()],
  packageDirectory,
  packagePrefix: '@goforgedev/compiler',
  version: application.version,
  licenseFile: path.join(root, '../LICENSE'),
  license: application.license,
});
const packed = {};
const vendor = path.join(root, 'vendor');
await mkdir(vendor, {recursive: true});
for (const platform of artifacts.keys())
{
  const result = JSON.parse(
    execFileSync(
      'npm',
      ['pack', '--ignore-scripts', '--json', '--pack-destination', vendor],
      {
        cwd: path.join(packageDirectory, platform),
        encoding: 'utf8',
        maxBuffer: 4 * 1024 * 1024,
      },
    ),
  )[0];
  const filename = result.filename.replace(
    '.tgz',
    `-${result.shasum.slice(0, 12)}.tgz`,
  );
  await rename(path.join(vendor, result.filename), path.join(vendor, filename));
  packed[platform] = {
    name: result.name,
    version: result.version,
    file: filename,
    integrity: result.integrity,
    shasum: result.shasum,
  };
}
await writeFile(
  path.join(root, 'native-packages.json'),
  JSON.stringify(packed, null, 2) + '\n',
);
const stage = path.join(root, '../npm/host-component');
await copyFile(
  path.join(directory, 'node-registration.mjs'),
  path.join(stage, 'node-registration.mjs'),
);
await copyFile(
  path.join(directory, 'native-artifacts.json'),
  path.join(stage, 'native-artifacts.json'),
);
for (const platform of Object.keys(nativeTargets))
{
  await rm(path.join(stage, `component.${platform}.cwasm`), {force: true});
  await rm(path.join(directory, `component.${platform}.cwasm`), {force: true});
}
const current = packed[`${process.platform}-${process.arch}`];
if (current)
{
  const sdk = JSON.parse(
    await readFile(path.join(root, 'sdk-packages.json'), 'utf8'),
  );
  const platform =
    sdk.platforms?.[`${process.platform}-${process.arch}`] ?? sdk.platform;
  const sdkFile = entry =>
    path.join(
      vendor,
      entry.file.replace('.tgz', `-${entry.shasum.slice(0, 12)}.tgz`),
    );
  for (const cwd of [root, path.join(root, '../npm')])
    execFileSync(
      'npm',
      [
        'install',
        '--offline',
        '--no-save',
        '--package-lock=false',
        '--ignore-scripts',
        '--no-audit',
        '--no-fund',
        sdkFile(platform),
        sdkFile(sdk.runtime),
        ...(cwd === root ? [sdkFile(sdk.build)] : []),
        path.join(vendor, current.file),
      ],
      {cwd, stdio: 'inherit'},
    );
}
console.log(
  `Packaged native components: ${Object.keys(packed).join(', ')}. No publication performed.`,
);
