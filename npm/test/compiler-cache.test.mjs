// Generated from templates/npm/test/compiler-cache.test.mjs by lawspec-dev generate. Do not edit.
// Where the compiler cache lives and whether a path fits Windows. There is
// no Windows machine in CI: the arithmetic runs on path.win32 with fixtures.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, readdir, rm, writeFile} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  buildLength,
  cacheLocation,
  cacheWarning,
  deepestEntry,
  longPathsEnabled,
  probeCache,
  windowsPathBudget,
  windowsPathLimit,
} from '../compiler-cache.mjs';
const build = '1152cb545a8623ac7fb5'.padEnd(64, '0');
test('the cache directory is chosen by flag, environment, manifest, then the project default', () =>
{
  const win = {
    configRoot: 'C:\\work\\service',
    cwd: 'C:\\work',
    pathModule: path.win32,
  };
  assert.deepEqual(cacheLocation({...win, env: {}}), {
    directory: 'C:\\work\\service\\.lawspec\\cache',
    owned: true,
    source: 'default',
  });
  assert.deepEqual(
    cacheLocation({...win, env: {}, config: {cacheDirectory: '..\\c'}}),
    {directory: 'C:\\work\\c', owned: false, source: ':cache-directory'},
  );
  assert.deepEqual(
    cacheLocation({
      ...win,
      env: {LAWSPEC_COMPILER_CACHE: 'D:\\lc'},
      config: {cacheDirectory: '..\\c'},
    }),
    {directory: 'D:\\lc', owned: false, source: 'LAWSPEC_COMPILER_CACHE'},
  );
  // A relative LAWSPEC_COMPILER_CACHE is relative to the working directory.
  assert.equal(
    cacheLocation({...win, env: {LAWSPEC_COMPILER_CACHE: 'lc'}}).directory,
    'C:\\work\\lc',
  );
  // The package cache's variable is not the compiler cache's.
  assert.equal(
    cacheLocation({...win, env: {LAWSPEC_CACHE_DIR: 'D:\\packages'}}).source,
    'default',
  );
  for (const off of [
    {options: {'no-cache': true}},
    {config: {cache: false}},
    {config: {cache: false, cacheDirectory: 'c'}},
  ])
    assert.equal(
      cacheLocation({...win, env: {LAWSPEC_COMPILER_CACHE: 'D:\\lc'}, ...off}),
      undefined,
    );
  const posix = {
    configRoot: '/work/service',
    cwd: '/work',
    pathModule: path.posix,
  };
  assert.equal(
    cacheLocation({...posix, env: {}}).directory,
    '/work/service/.lawspec/cache',
  );
});
test('an entry is at most 54 characters below the cache directory', () =>
{
  const root = 'C:\\c';
  const entry = deepestEntry(root, build, path.win32);
  assert.equal(entry.length, root.length + 54);
  assert.equal(path.win32.relative(root, entry).split('\\').length, 3);
  assert.equal(
    path.win32.relative(root, entry).split('\\')[0].length,
    buildLength,
  );
  assert.equal(deepestEntry('/c', build, path.posix).length, 2 + 54);
});
test('the reported project path fits Windows with the short layout and did not with the old one', () =>
{
  // The report's layout, <project>\.lawspec\cache\<16>\<64>\lawspec-0.32.0\
  // <stage>\<64>, wrote only expand and plan. That happens at a project path
  // of 70 characters (the report's 85 would have written nothing).
  const project = 'C:\\' + 'p'.repeat(67);
  assert.equal(project.length, 70);
  const cache = path.win32.join(project, '.lawspec', 'cache');
  const old = stage =>
    path.win32.join(
      cache,
      build.slice(0, 16),
      build,
      'lawspec-0.32.0',
      stage,
      build,
    );
  const written = stage => (old(stage) + '.tmp').length <= windowsPathLimit;
  assert.deepEqual(
    [
      'expand',
      'plan',
      'elaborate',
      'validate',
      'definition-templates',
      'emit-product',
      'typed-jvm-function',
    ].filter(written),
    ['expand', 'plan'],
  );
  const budget = windowsPathBudget(cache, build);
  assert.equal(budget.length, 70 + '\\.lawspec\\cache'.length + 54);
  assert.equal(budget.fits, true);
  // The longest project path that still fits, and the first that does not.
  const longest = windowsPathLimit - 54 - '\\.lawspec\\cache'.length;
  const at = length =>
    windowsPathBudget(
      path.win32.join('C:\\' + 'p'.repeat(length - 3), '.lawspec', 'cache'),
      build,
    );
  assert.equal(at(longest).length, windowsPathLimit);
  assert.equal(at(longest).fits, true);
  assert.equal(at(longest + 1).fits, false);
  assert.equal(longest, 190);
  // A short shared directory fits wherever the project is.
  assert.equal(
    windowsPathBudget('C:\\Users\\someone\\AppData\\Local\\lawspec', build)
      .fits,
    true,
  );
});
test('a cache failure is one warning with the reason and the path length', () =>
{
  const long = 'C:\\' + 'p'.repeat(250) + '\\zzz\\' + 'z'.repeat(32);
  const windows = cacheWarning({path: long, reason: 'does not exist'}, 'win32');
  assert.match(windows, /the compiler cache is not being written/);
  assert.match(windows, /does not exist/);
  assert.match(windows, new RegExp(`path of ${long.length} characters`));
  assert.match(windows, /LongPathsEnabled/);
  assert.match(windows, /LAWSPEC_COMPILER_CACHE or :cache-directory/);
  const posix = cacheWarning(
    {path: '/c/x', reason: 'permission denied'},
    'linux',
  );
  assert.match(posix, /permission denied \(path of 4 characters: \/c\/x\)/);
  assert.doesNotMatch(posix, /LongPathsEnabled/);
  assert.match(posix, /lawspec doctor/);
  // A short Windows path that fails is not blamed on the path limit.
  assert.doesNotMatch(
    cacheWarning({path: 'C:\\c\\x', reason: 'access denied'}, 'win32'),
    /LongPathsEnabled/,
  );
});
test('LongPathsEnabled is read from the registry on win32 only', async () =>
{
  const answer = value => async (command, args) =>
  {
    assert.equal(command, 'reg');
    assert.deepEqual(args.slice(0, 2), [
      'query',
      'HKLM\\SYSTEM\\CurrentControlSet\\Control\\FileSystem',
    ]);
    return {
      stdout: `\r\nHKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Control\\FileSystem\r\n    LongPathsEnabled    REG_DWORD    ${value}\r\n\r\n`,
    };
  };
  assert.equal(await longPathsEnabled('win32', answer('0x0')), false);
  assert.equal(await longPathsEnabled('win32', answer('0x1')), true);
  assert.equal(
    await longPathsEnabled('win32', async () =>
    {
      throw new Error(
        'ERROR: The system was unable to find the specified registry key or value.',
      );
    }),
    null,
  );
  assert.equal(
    await longPathsEnabled('win32', async () => ({stdout: ''})),
    null,
  );
  assert.equal(
    await longPathsEnabled('linux', async () =>
    {
      throw new Error('not consulted');
    }),
    null,
  );
});
test('the doctor probe writes the deepest entry and leaves nothing behind', async t =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-cache-probe-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  const directory = path.join(root, 'cache');
  const ready = await probeCache({directory, source: 'default'}, build);
  assert.equal(ready.ok, true);
  assert.equal(ready.target, 'compiler cache');
  assert.equal(ready.pathLength, directory.length + 54);
  assert.match(ready.detail, /deepest entry \d+ characters/);
  assert.deepEqual(await readdir(root), []);
  // A file where the directory should be: reported, with what to do.
  await writeFile(directory, '');
  const blocked = await probeCache(
    {directory, source: ':cache-directory'},
    build,
  );
  assert.equal(blocked.ok, false);
  assert.match(blocked.message, /cannot be written/);
  assert.match(blocked.message, /path of \d+ characters/);
  assert.match(blocked.instructions, /LAWSPEC_COMPILER_CACHE/);
  assert.deepEqual(await readdir(root), ['cache']);
  // On Windows the report carries the registry setting either way.
  const windows = await probeCache(
    {directory, source: 'default'},
    build,
    'win32',
  );
  assert.equal(windows.ok, false);
  assert.match(windows.instructions, /LongPathsEnabled/);
});
test('the doctor probe keeps an existing build folder and its entries', async t =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-cache-probe-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  const entry = deepestEntry(root, build);
  const kept = path.join(path.dirname(entry), 'kept');
  const {mkdir} = await import('node:fs/promises');
  await mkdir(path.dirname(entry), {recursive: true});
  await writeFile(kept, 'entry');
  assert.equal(
    (await probeCache({directory: root, source: 'default'}, build)).ok,
    true,
  );
  assert.deepEqual(await readdir(path.dirname(entry)), ['kept']);
});
