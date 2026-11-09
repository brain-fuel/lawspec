// Generated from templates/component/tools/install-sdk.mjs by lawspec-dev generate. Do not edit.
// Copies immutable local tarballs and installs packages; no cross-repository source imports.
// ref:DEC-host-sdk-independent-consumer
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {fileURLToPath} from 'node:url';
import path from 'node:path';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const input = process.argv[2];
if (!input) throw new Error('usage: install-sdk.mjs <SDK tarball directory>');
const source = path.resolve(input);
const packages = JSON.parse(
  await readFile(path.join(source, 'packages.json'), 'utf8'),
);
await mkdir(path.join(root, 'vendor'), {recursive: true});
const files = {};
const platform = `${process.platform}-${process.arch}`;
const inputs = {
  runtime: packages.runtime,
  build: packages.build,
  ...Object.fromEntries(
    Object.entries(packages.platforms ?? {[platform]: packages.platform}).map(
      ([target, entry]) => [`platform:${target}`, entry],
    ),
  ),
};
for (const [name, entry] of Object.entries(inputs))
{
  const bytes = await readFile(path.join(source, entry.file));
  if (
    'sha512-' + createHash('sha512').update(bytes).digest('base64') !==
    entry.integrity
  )
    throw new Error('SDK package integrity mismatch');
  const file = path.join(
    root,
    'vendor',
    entry.file.replace('.tgz', `-${entry.shasum.slice(0, 12)}.tgz`),
  );
  await writeFile(file, bytes);
  files[name] = file;
}
const install = (cwd, inputs) =>
  execFileSync(
    'npm',
    [
      'install',
      '--no-save',
      '--package-lock=false',
      '--ignore-scripts',
      '--no-audit',
      '--no-fund',
      ...inputs,
    ],
    {cwd, stdio: 'inherit'},
  );
if (!files[`platform:${platform}`])
  throw new Error(`SDK distribution has no native helper for ${platform}`);
install(root, [files[`platform:${platform}`], files.runtime, files.build]);
install(path.join(root, '../npm'), [
  files[`platform:${platform}`],
  files.runtime,
]);
await writeFile(
  path.join(root, 'sdk-packages.json'),
  JSON.stringify(packages, null, 2) + '\n',
);
console.log(
  'Installed packed SDK dependencies in LawSpec; no publication performed.',
);
