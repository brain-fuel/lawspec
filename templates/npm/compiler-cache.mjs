// Where the compiler keeps work between runs, and whether that place can
// hold it. The compiler names its entries (LawSpec.Memo.entryLocation): this
// module only chooses the directory, measures paths and probes the disk.
import {execFile} from 'node:child_process';
import {mkdir, rm, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {promisify} from 'node:util';
// An entry is <directory>/<build>/<table>/<entry>: 16, 3 and 32 characters.
// Windows refuses a path of 260 characters or more unless long paths are
// enabled, and a directory of 248 or more.
export const buildLength = 16;
const tableLength = 3;
const entryLength = 32;
export const windowsPathLimit = 259;
const windowsDirectoryLimit = 247;
// The directory a command uses, or undefined when it keeps no cache.
// --no-cache and `:cache false` come first. LAWSPEC_COMPILER_CACHE (relative
// to the working directory) overrides `:cache-directory` (relative to the
// manifest); otherwise the project's own .lawspec/cache, which LawSpec owns:
// it is the only one it writes a .gitignore into and removes old builds from.
export function cacheLocation({
  options = {},
  config = {},
  configRoot,
  env = process.env,
  cwd = process.cwd(),
  pathModule = path,
})
{
  if (options['no-cache'] || config.cache === false) return undefined;
  if (env.LAWSPEC_COMPILER_CACHE)
    return {
      directory: pathModule.resolve(cwd, env.LAWSPEC_COMPILER_CACHE),
      owned: false,
      source: 'LAWSPEC_COMPILER_CACHE',
    };
  if (config.cacheDirectory !== undefined)
    return {
      directory: pathModule.resolve(configRoot, config.cacheDirectory),
      owned: false,
      source: ':cache-directory',
    };
  return {
    directory: pathModule.join(configRoot, '.lawspec', 'cache'),
    owned: true,
    source: 'default',
  };
}
// The longest path the compiler writes below a cache directory. An entry's
// temporary file is as long as the entry.
export function deepestEntry(directory, build, pathModule = path)
{
  return pathModule.join(
    directory,
    build.slice(0, buildLength).padEnd(buildLength, '0'),
    'z'.repeat(tableLength),
    'z'.repeat(entryLength),
  );
}
// Whether that path fits Windows' limits without long paths enabled.
export function windowsPathBudget(directory, build, pathModule = path.win32)
{
  const entry = deepestEntry(directory, build, pathModule);
  const folder = pathModule.dirname(entry);
  return {
    entry,
    length: entry.length,
    limit: windowsPathLimit,
    fits:
      entry.length <= windowsPathLimit &&
      folder.length <= windowsDirectoryLimit,
  };
}
// One warning for an entry the compiler could not store.
export function cacheWarning(failure, platform = process.platform)
{
  const length = failure.path.length;
  const tooLong = platform === 'win32' && length > windowsPathLimit - 12;
  return (
    `lawspec: warning: the compiler cache is not being written, so later runs repeat this work. ${failure.reason} ` +
    `(path of ${length} characters: ${failure.path})` +
    (tooLong
      ? `\nWindows limits a path to ${windowsPathLimit} characters unless LongPathsEnabled is set. Set LAWSPEC_COMPILER_CACHE or :cache-directory to a short directory, and run lawspec doctor.`
      : '\nRun lawspec doctor to check the cache directory, or pass --no-cache.')
  );
}
// LongPathsEnabled from the registry: true, false, or null when it cannot be
// read (and on every other platform).
export async function longPathsEnabled(
  platform = process.platform,
  run = promisify(execFile),
)
{
  if (platform !== 'win32') return null;
  try
  {
    const {stdout} = await run('reg', [
      'query',
      'HKLM\\SYSTEM\\CurrentControlSet\\Control\\FileSystem',
      '/v',
      'LongPathsEnabled',
    ]);
    const value = /LongPathsEnabled\s+REG_DWORD\s+0x([0-9a-fA-F]+)/.exec(stdout);
    return value ? parseInt(value[1], 16) !== 0 : null;
  }
  catch
  {
    return null;
  }
}
// Create and remove the deepest path the compiler would write, the way it
// writes one: the folders, a file, and nothing left behind that was not
// there before.
export async function probeCache(location, build, platform = process.platform)
{
  const entry = deepestEntry(location.directory, build);
  const folder = path.dirname(entry);
  const report = {
    target: 'compiler cache',
    kind: 'cache',
    directory: location.directory,
    source: location.source,
    pathLength: entry.length,
    longPathsEnabled: await longPathsEnabled(platform),
  };
  let created;
  try
  {
    created = await mkdir(folder, {recursive: true});
    await writeFile(entry, '');
    await rm(entry);
    report.ok = true;
  }
  catch (error)
  {
    report.ok = false;
    report.message = `the compiler cache cannot be written: ${error.message} (path of ${entry.length} characters: ${entry})`;
    report.instructions =
      (platform === 'win32' && report.longPathsEnabled !== true
        ? `Windows limits a path to ${windowsPathLimit} characters while LongPathsEnabled is ${report.longPathsEnabled === false ? '0' : 'not set or unreadable'}. `
        : '') +
      'Set LAWSPEC_COMPILER_CACHE, or :cache-directory in lawspec.edn, to a short writable directory. Until then every run compiles from nothing.';
  }
  // Only what this probe created is removed: an existing build keeps its entries.
  if (created) await rm(created, {recursive: true, force: true});
  if (report.ok)
    report.detail =
      `ready (${location.directory}; deepest entry ${entry.length} characters` +
      (platform === 'win32'
        ? `; LongPathsEnabled ${report.longPathsEnabled === null ? 'unreadable' : report.longPathsEnabled ? '1' : '0'}`
        : '') +
      ')';
  return report;
}
