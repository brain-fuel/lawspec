#!/usr/bin/env node
// Generated from templates/tools/npm-lock.mjs by lawspec-dev generate. Do not edit.
// Keeps npm/package-lock.json complete, so `npm ci` in npm/ can verify every
// package, including the optional native compiler packages.
//
//   node tools/npm-lock.mjs          regenerate the lock (uses the registry)
//   node tools/npm-lock.mjs --check  verify it against npm/package.json and
//                                    component/native-packages.json (offline)
//
// The registry resolves the published dependencies. The compiler packages of
// the version being prepared are not published until release, so their
// entries come from component/native-packages.json, which records the packed
// tarballs' integrity. Publishing other tarballs makes `npm ci` fail closed.
import {execFileSync} from 'node:child_process';
import {mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const manifestPath = path.join(root, 'npm/package.json');
const lockPath = path.join(root, 'npm/package-lock.json');
const nativePath = path.join(root, 'component/native-packages.json');
const compilerPrefix = '@goforgedev/compiler-';

const readJson = async file => JSON.parse(await readFile(file, 'utf8'));

const sorted = object =>
  Object.fromEntries(
    Object.entries(object).sort(([left], [right]) =>
      left.localeCompare(right, 'en'),
    ),
  );

// The lock entry npm writes for a platform package: identity first, then the
// remaining fields in alphabetical order.
function compilerEntry(platform, record)
{
  const [system, cpu] = platform.split('-');
  const basename = record.name.slice(record.name.indexOf('/') + 1);
  return {
    version: record.version,
    resolved: `https://registry.npmjs.org/${record.name}/-/${basename}-${record.version}.tgz`,
    integrity: record.integrity,
    cpu: [cpu],
    ...(system === 'linux' ? {libc: ['glibc']} : {}),
    license: 'MIT',
    optional: true,
    os: [system],
  };
}

function compilerEntries(manifest, native)
{
  const wanted = Object.entries(manifest.optionalDependencies ?? {}).filter(
    ([name]) => name.startsWith(compilerPrefix),
  );
  const entries = {};
  for (const [name, version] of wanted)
  {
    const found = Object.entries(native).find(
      ([, record]) => record.name === name,
    );
    if (!found)
      throw new Error(
        `${name} has no record in component/native-packages.json`,
      );
    const [platform, record] = found;
    if (record.version !== version)
      throw new Error(
        `${name}: package.json wants ${version}, ` +
          `component/native-packages.json records ${record.version}`,
      );
    entries[`node_modules/${name}`] = compilerEntry(platform, record);
  }
  return entries;
}

async function generate(manifest, native)
{
  const directory = await mkdtemp(path.join(os.tmpdir(), 'lawspec-lock-'));
  try
  {
    const published = Object.fromEntries(
      Object.entries(manifest.optionalDependencies ?? {}).filter(
        ([name]) => !name.startsWith(compilerPrefix),
      ),
    );
    await writeFile(
      path.join(directory, 'package.json'),
      JSON.stringify({...manifest, optionalDependencies: published}, null, 2),
    );
    execFileSync(
      'npm',
      [
        'install',
        '--package-lock-only',
        '--ignore-scripts',
        '--no-audit',
        '--no-fund',
      ],
      {cwd: directory, stdio: ['ignore', 'ignore', 'inherit']},
    );
    const lock = await readJson(path.join(directory, 'package-lock.json'));
    lock.packages[''].optionalDependencies = sorted(
      manifest.optionalDependencies ?? {},
    );
    lock.packages = {
      '': lock.packages[''],
      ...sorted({
        ...Object.fromEntries(
          Object.entries(lock.packages).filter(([key]) => key !== ''),
        ),
        ...compilerEntries(manifest, native),
      }),
    };
    return lock;
  }
  finally
  {
    await rm(directory, {recursive: true, force: true});
  }
}

function problems(manifest, native, lock)
{
  const found = [];
  const rootEntry = lock.packages?.[''] ?? {};
  if (
    lock.version !== manifest.version ||
    rootEntry.version !== manifest.version
  )
    found.push(
      `lock version ${lock.version} is not package.json's ${manifest.version}`,
    );
  for (const field of ['dependencies', 'optionalDependencies'])
  {
    const wanted = JSON.stringify(sorted(manifest[field] ?? {}));
    const locked = JSON.stringify(sorted(rootEntry[field] ?? {}));
    if (wanted !== locked) found.push(`lock ${field} differ from package.json`);
    for (const [name, version] of Object.entries(manifest[field] ?? {}))
    {
      const entry = lock.packages?.[`node_modules/${name}`];
      if (!entry) found.push(`${name}@${version} is missing from the lock`);
      else if (entry.version !== version)
        found.push(`${name}: lock has ${entry.version}, not ${version}`);
      else if (!entry.integrity)
        found.push(`${name}@${version} has no integrity in the lock`);
    }
  }
  let expected = {};
  try
  {
    expected = compilerEntries(manifest, native);
  }
  catch (error)
  {
    found.push(error.message);
  }
  for (const [key, entry] of Object.entries(expected))
    if (JSON.stringify(lock.packages?.[key]) !== JSON.stringify(entry))
      found.push(`${key} differs from component/native-packages.json`);
  return found;
}

const manifest = await readJson(manifestPath);
const native = await readJson(nativePath);
if (process.argv.includes('--check'))
{
  const found = problems(manifest, native, await readJson(lockPath));
  if (found.length > 0)
  {
    for (const problem of found)
      console.error(`npm/package-lock.json: ${problem}`);
    console.error('Run: node tools/npm-lock.mjs');
    process.exit(1);
  }
  console.log(`npm/package-lock.json pins all of lawspec@${manifest.version}.`);
}
else
{
  const lock = await generate(manifest, native);
  await writeFile(lockPath, JSON.stringify(lock, null, 2) + '\n');
  const found = problems(manifest, native, lock);
  if (found.length > 0) throw new Error(found.join('; '));
  console.log(`Wrote npm/package-lock.json for lawspec@${manifest.version}.`);
}
