#!/usr/bin/env node
// Keeps npm/package-lock.json complete, so `npm ci` in npm/ can verify every
// package, including the optional native compiler and Canon packages.
//
//   node tools/npm-lock.mjs          regenerate the lock (uses the registry)
//   node tools/npm-lock.mjs --check  verify it against npm/package.json and
//                                    the platform packages' records (offline)
//
// The registry resolves the published dependencies. The platform packages of
// the version being prepared are not published until release, so their
// entries come from the records of the packed tarballs' integrity:
// component/native-packages.json for @goforgedev/compiler-<platform>
// (glibc on Linux) and component/canon-packages.json for
// @goforgedev/canon-<platform> (static on Linux; tools/package-canon.sh).
// Publishing other tarballs makes `npm ci` fail closed.
import {execFileSync} from 'node:child_process';
import {mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
const manifestPath = path.join(root, 'npm/package.json');
const lockPath = path.join(root, 'npm/package-lock.json');
// Each unpublished platform package family: its name prefix, its record and
// whether its Linux packages name a libc.
const families = [
  {
    prefix: '@goforgedev/compiler-',
    record: 'component/native-packages.json',
    libc: ['glibc'],
  },
  {prefix: '@goforgedev/canon-', record: 'component/canon-packages.json'},
];
const unpublished = name =>
  families.some(family => name.startsWith(family.prefix));

const readJson = async file => JSON.parse(await readFile(file, 'utf8'));

const sorted = object =>
  Object.fromEntries(
    Object.entries(object).sort(([left], [right]) =>
      left.localeCompare(right, 'en'),
    ),
  );

// The lock entry npm writes for a platform package: identity first, then the
// remaining fields in alphabetical order.
function platformEntry(platform, record, libc)
{
  const [system, cpu] = platform.split('-');
  const basename = record.name.slice(record.name.indexOf('/') + 1);
  return {
    version: record.version,
    resolved: `https://registry.npmjs.org/${record.name}/-/${basename}-${record.version}.tgz`,
    integrity: record.integrity,
    cpu: [cpu],
    ...(system === 'linux' && libc ? {libc} : {}),
    license: 'MIT',
    optional: true,
    os: [system],
  };
}

function platformEntries(manifest, records)
{
  const entries = {};
  for (const family of families)
  {
    const wanted = Object.entries(manifest.optionalDependencies ?? {}).filter(
      ([name]) => name.startsWith(family.prefix),
    );
    for (const [name, version] of wanted)
    {
      const found = Object.entries(records[family.record]).find(
        ([, record]) => record.name === name,
      );
      if (!found)
        throw new Error(`${name} has no record in ${family.record}`);
      const [platform, record] = found;
      if (record.version !== version)
        throw new Error(
          `${name}: package.json wants ${version}, ` +
            `${family.record} records ${record.version}`,
        );
      entries[`node_modules/${name}`] = platformEntry(
        platform,
        record,
        family.libc,
      );
    }
  }
  return entries;
}

async function generate(manifest, records)
{
  const directory = await mkdtemp(path.join(os.tmpdir(), 'lawspec-lock-'));
  try
  {
    const published = Object.fromEntries(
      Object.entries(manifest.optionalDependencies ?? {}).filter(
        ([name]) => !unpublished(name),
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
        ...platformEntries(manifest, records),
      }),
    };
    return lock;
  }
  finally
  {
    await rm(directory, {recursive: true, force: true});
  }
}

function problems(manifest, records, lock)
{
  const found = [];
  const rootEntry = lock.packages?.[''] ?? {};
  if (lock.version !== manifest.version || rootEntry.version !== manifest.version)
    found.push(
      `lock version ${lock.version} is not package.json's ${manifest.version}`,
    );
  for (const field of ['dependencies', 'devDependencies', 'optionalDependencies'])
  {
    const wanted = JSON.stringify(sorted(manifest[field] ?? {}));
    const locked = JSON.stringify(sorted(rootEntry[field] ?? {}));
    if (wanted !== locked)
      found.push(`lock ${field} differ from package.json`);
    for (const [name, version] of Object.entries(manifest[field] ?? {}))
    {
      const entry = lock.packages?.[`node_modules/${name}`];
      if (!entry)
        found.push(`${name}@${version} is missing from the lock`);
      else if (entry.version !== version)
        found.push(`${name}: lock has ${entry.version}, not ${version}`);
      else if (!entry.integrity)
        found.push(`${name}@${version} has no integrity in the lock`);
    }
  }
  let expected = {};
  try
  {
    expected = platformEntries(manifest, records);
  }
  catch (error)
  {
    found.push(error.message);
  }
  for (const [key, entry] of Object.entries(expected))
    if (JSON.stringify(lock.packages?.[key]) !== JSON.stringify(entry))
      found.push(`${key} differs from its packed tarball's record`);
  return found;
}

const manifest = await readJson(manifestPath);
const records = Object.fromEntries(
  await Promise.all(
    families.map(async family => [
      family.record,
      await readJson(path.join(root, family.record)).catch(error =>
      {
        if (error.code === 'ENOENT') return {};
        throw error;
      }),
    ]),
  ),
);
if (process.argv.includes('--check'))
{
  const found = problems(manifest, records, await readJson(lockPath));
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
  const lock = await generate(manifest, records);
  await writeFile(lockPath, JSON.stringify(lock, null, 2) + '\n');
  const found = problems(manifest, records, lock);
  if (found.length > 0)
    throw new Error(found.join('; '));
  console.log(`Wrote npm/package-lock.json for lawspec@${manifest.version}.`);
}
