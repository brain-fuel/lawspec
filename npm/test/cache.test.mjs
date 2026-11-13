// Generated from templates/npm/test/cache.test.mjs by lawspec-dev generate. Do not edit.
import {configEDN} from './manifest-fixtures.mjs';
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {
  mkdtemp,
  mkdir,
  readdir,
  readFile,
  writeFile,
  rm,
} from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
const exec = promisify(execFile);
const cli = new URL('../bin/lawspec.mjs', import.meta.url).pathname;
const spec =
  [
    'unit cache.example\n\n',
    'double :: Int32 -> Int32',
    `function twice (x :: Integer) -> Integer is x + x end function
`,
    `law twiceDoubles is definition: for all (x :: Integer) => twice x must be x * 2 end for all end definition end law
`,
    `law deterministic is definition: for all (x :: Int32) => double x must be double x end for all end definition end law
`,
    'end unit',
  ].join('\n') + '\n';
async function project(t, config = {})
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-cache-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  await mkdir(path.join(root, 'laws'));
  await writeFile(path.join(root, 'laws/example.lawspec'), spec);
  await writeFile(
    path.join(root, 'lawspec.edn'),
    configEDN({
      manifestVersion: 1,
      languageProfile: '1.0-rc.2',
      verification: {layers: []},
      sources: ['laws'],
      targets: [{language: 'python', root: '.'}],
      ...config,
    }),
  );
  return root;
}
const check = (root, ...flags) =>
  exec(process.execPath, [cli, 'check', '--json', ...flags], {cwd: root}).then(
    result => result.stdout,
  );
async function entries(folder)
{
  const found = [];
  for (const entry of await readdir(folder, {withFileTypes: true}))
    if (entry.isDirectory())
      found.push(...(await entries(path.join(folder, entry.name))));
    else found.push(path.join(folder, entry.name));
  return found;
}
test('check reuses work kept in .lawspec/cache, and recovers from a damaged entry', async t =>
{
  const root = await project(t);
  const first = await check(root);
  const cache = path.join(root, '.lawspec/cache');
  assert.equal(await readFile(path.join(cache, '.gitignore'), 'utf8'), '*\n');
  const builds = (await readdir(cache)).filter(name => name !== '.gitignore');
  assert.equal(builds.length, 1);
  const stored = await entries(path.join(cache, builds[0]));
  assert.ok(stored.length > 0);
  assert.equal(await check(root), first);
  await writeFile(stored[0], 'damaged');
  assert.equal(await check(root), first);
  // Another compiler build's folder is removed.
  await mkdir(path.join(cache, '0000000000000000'));
  await check(root);
  assert.deepEqual(
    (await readdir(cache)).sort(),
    ['.gitignore', builds[0]].sort(),
  );
});
test('--no-cache and cache: false keep no cache', async t =>
{
  const flagged = await project(t);
  await check(flagged, '--no-cache');
  await assert.rejects(readdir(path.join(flagged, '.lawspec/cache')));
  const configured = await project(t, {cache: false});
  await check(configured);
  await assert.rejects(readdir(path.join(configured, '.lawspec/cache')));
  const invalid = await project(t, {cache: 'yes'});
  await assert.rejects(check(invalid), error =>
    /cache must be true or false/.test(error.stdout + error.stderr),
  );
});

// SDK caches use the caller's actual host directories, including absolute
// paths, while the compiler sees only its dedicated WASI mount.
test('SDK cache roots are explicit mounts and concurrent root changes stay isolated', async t =>
{
  const {createCompiler} = await import('../api.mjs');
  const roots = await Promise.all(
    [0, 1].map(() => mkdtemp(path.join(os.tmpdir(), 'lawspec-sdk-cache-'))),
  );
  t.after(() =>
    Promise.all(roots.map(root => rm(root, {recursive: true, force: true}))),
  );
  const compiler = await createCompiler();
  const request = cacheDirectory => ({
    schemaVersion: 5,
    languageProfile: '1.0-rc.2',
    cacheDirectory,
    verification: {layers: []},
    sources: [{path: 'input.lawspec', content: spec}],
  });
  const results = await Promise.all(
    roots.map(root => compiler.check(request(root))),
  );
  assert.deepEqual(results[0], results[1]);
  assert.deepEqual(results[0].diagnostics, []);
  for (const root of roots)
  {
    assert.ok((await entries(root)).length > 0);
    const accidental = path.join(process.cwd(), root.replace(/^[/\\]+/, ''));
    await assert.rejects(readdir(accidental), {code: 'ENOENT'});
  }
  assert.deepEqual(await compiler.check(request(roots[0])), results[0]);
});

test('SDK persisted compiler memos are separated by the actual WASM binary', async t =>
{
  const {copyFile, appendFile} = await import('node:fs/promises');
  const {createHash} = await import('node:crypto');
  const {fileURLToPath} = await import('node:url');
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-sdk-build-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  const cache = path.join(root, 'cache'),
    variant = path.join(root, 'variant');
  await mkdir(variant);
  for (const file of ['api.mjs', 'launcher.mjs', 'core_jsffi.js', 'core.wasm'])
    await copyFile(
      new URL('../' + file, import.meta.url),
      path.join(variant, file),
    );
  await writeFile(path.join(variant, 'package.json'), '{"type":"module"}\n');
  // A valid custom section changes the actual binary without changing its
  // compiler behavior. Both real builds must keep separate disk entries.
  const name = Buffer.from('lawspec-cache-test');
  const payload = Buffer.concat([
    Buffer.from([name.length]),
    name,
    Buffer.from([1]),
  ]);
  await appendFile(
    path.join(variant, 'core.wasm'),
    Buffer.concat([Buffer.from([0, payload.length]), payload]),
  );
  const input = {
    schemaVersion: 5,
    languageProfile: '1.0-rc.2',
    cacheDirectory: cache,
    verification: {layers: []},
    sources: [{path: 'input.lawspec', content: spec}],
  };
  const first = await import('../api.mjs');
  const expected = await (await first.createCompiler()).check(input);
  assert.deepEqual(expected.diagnostics, []);
  const child = `import {createCompiler} from ${JSON.stringify(new URL('file://' + path.join(variant, 'api.mjs')).href)};console.log(JSON.stringify(await(await createCompiler()).check(${JSON.stringify(input)})));`;
  const actual = JSON.parse(
    (await exec(process.execPath, ['--input-type=module', '-e', child])).stdout,
  );
  assert.deepEqual(actual, expected);
  const hash = async file =>
    createHash('sha256')
      .update(await readFile(file))
      .digest('hex');
  const builds = [
    await hash(fileURLToPath(new URL('../core.wasm', import.meta.url))),
    await hash(path.join(variant, 'core.wasm')),
  ];
  assert.notEqual(builds[0], builds[1]);
  const folders = builds.map(build => build.slice(0, 16));
  assert.deepEqual((await readdir(cache)).sort(), folders.sort());
  for (const folder of folders)
    assert.ok((await entries(path.join(cache, folder))).length > 0);
});

const run = (root, args, env = {}) =>
  exec(process.execPath, [cli, ...args], {
    cwd: root,
    env: {...process.env, ...env},
  });
test('an entry is three short names below the cache directory', async t =>
{
  const root = await project(t);
  await check(root);
  const cache = path.join(root, '.lawspec/cache');
  const stored = (await entries(cache)).filter(
    file => path.basename(file) !== '.gitignore',
  );
  assert.ok(stored.length > 0);
  for (const file of stored)
  {
    const parts = path.relative(cache, file).split(path.sep);
    assert.deepEqual(
      parts.map(part => part.length),
      [16, 3, 32],
      file,
    );
    assert.match(parts[2], /^[a-z2-7]{32}$/);
  }
});
test('check and its advice share one cache; advise and inspect keep none', async t =>
{
  const quiet = await project(t);
  await run(quiet, ['advise', '--json']);
  await run(quiet, ['inspect', '--target', 'python', '--json']);
  await assert.rejects(readdir(path.join(quiet, '.lawspec')), {code: 'ENOENT'});
  const root = await project(t);
  const first = await check(root);
  assert.ok(JSON.parse(first).advice);
  assert.equal(await check(root), first);
  assert.equal(await check(root, '--no-cache'), first);
  // The advice inspects the target, and its compact layout is kept.
  const cache = path.join(root, '.lawspec/cache');
  const before = (await entries(cache)).length;
  await check(root);
  assert.equal((await entries(cache)).length, before);
});
test('SDK inspect and advise use a cache directory only with cacheAdvisory', async t =>
{
  const {createCompiler} = await import('../api.mjs');
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-advisory-cache-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  const compiler = await createCompiler();
  const request = {
    schemaVersion: 5,
    languageProfile: '1.0-rc.2',
    cacheDirectory: root,
    verification: {layers: []},
    sources: [{path: 'input.lawspec', content: spec}],
    target: 'python',
  };
  const plain = await compiler.inspect(request);
  assert.deepEqual(plain.diagnostics, []);
  assert.deepEqual(await entries(root), []);
  // A compiler that has not compiled this yet: what one instance already
  // holds in memory it does not store again.
  const cached = await (
    await createCompiler()
  ).inspect({
    ...request,
    cacheAdvisory: true,
  });
  assert.deepEqual(cached, plain);
  const stored = (await entries(root)).length;
  assert.ok(stored > 0);
  // A new compiler reads them, and stores nothing more.
  const again = await (
    await createCompiler()
  ).inspect({
    ...request,
    cacheAdvisory: true,
  });
  assert.deepEqual(again, plain);
  assert.equal((await entries(root)).length, stored);
});
test(':cache-directory and LAWSPEC_COMPILER_CACHE move the cache, and nothing else is removed there', async t =>
{
  const shared = await mkdtemp(path.join(os.tmpdir(), 'lawspec-shared-cache-'));
  t.after(() => rm(shared, {recursive: true, force: true}));
  await mkdir(path.join(shared, '0000000000000000'));
  const configured = await project(t, {cacheDirectory: shared});
  const first = await check(configured);
  await assert.rejects(readdir(path.join(configured, '.lawspec')), {
    code: 'ENOENT',
  });
  const builds = (await readdir(shared)).sort();
  assert.equal(builds.length, 2);
  assert.ok(builds.includes('0000000000000000'));
  // Another project, with the directory named by the environment.
  const other = await project(t);
  const elsewhere = await mkdtemp(path.join(os.tmpdir(), 'lawspec-env-cache-'));
  t.after(() => rm(elsewhere, {recursive: true, force: true}));
  assert.equal(
    (await run(other, ['check', '--json'], {LAWSPEC_COMPILER_CACHE: elsewhere}))
      .stdout,
    first,
  );
  assert.ok((await entries(elsewhere)).length > 0);
  await assert.rejects(readdir(path.join(other, '.lawspec')), {code: 'ENOENT'});
  // The environment variable wins over the manifest.
  const count = (await entries(shared)).length;
  await run(configured, ['check', '--json'], {
    LAWSPEC_COMPILER_CACHE: elsewhere,
  });
  assert.equal((await entries(shared)).length, count);
  const invalid = await project(t, {cacheDirectory: ''});
  await assert.rejects(check(invalid), error =>
    /cacheDirectory must be the path of a directory/.test(
      error.stdout + error.stderr,
    ),
  );
});
test('a cache that cannot be written is one warning, and the result is unchanged', async t =>
{
  const root = await project(t);
  const expected = await check(root, '--no-cache');
  const blocked = path.join(root, 'blocked');
  await writeFile(blocked, 'a file where the cache directory should be');
  const result = await run(root, ['check', '--json'], {
    LAWSPEC_COMPILER_CACHE: path.join(blocked, 'cache'),
  });
  assert.equal(result.stdout, expected);
  const warnings = result.stderr
    .split('\n')
    .filter(line => line.includes('the compiler cache is not being written'));
  assert.equal(warnings.length, 1, result.stderr);
  assert.match(warnings[0], /path of \d+ characters/);
});
test("--timings prints each compiler request's stages on standard error only", async t =>
{
  const root = await project(t);
  const plain = await check(root, '--no-cache');
  const timed = await run(root, ['check', '--json', '--no-cache', '--timings']);
  assert.equal(timed.stdout, plain);
  assert.match(timed.stderr, /^lawspec timings: check \(\d+ ms\)$/m);
  assert.match(timed.stderr, /^lawspec timings: inspect python \(\d+ ms\)$/m);
  assert.match(timed.stderr, /^  parse +\d+ ms/m);
  assert.match(timed.stderr, /^  validate cache\.example +\d+ ms/m);
  assert.match(timed.stderr, /^  emit python +\d+ ms/m);
  // The second request finds the compiled program in memory: no parse row.
  const second = timed.stderr.slice(
    timed.stderr.indexOf('lawspec timings: inspect'),
  );
  assert.doesNotMatch(second, /^  parse /m);
});
test('doctor checks the compiler cache and leaves the project as it was', async t =>
{
  const root = await project(t);
  const result = await run(root, ['doctor']).catch(error => error);
  assert.match(
    result.stdout,
    /^compiler cache: ready \(.*deepest entry \d+ characters\)$/m,
  );
  await assert.rejects(readdir(path.join(root, '.lawspec')), {code: 'ENOENT'});
  const off = await run(root, ['doctor', '--no-cache']).catch(error => error);
  assert.doesNotMatch(off.stdout, /compiler cache/);
});

test('evaluation settings survive EDN and cold, warm and disabled compiler caches', async t =>
{
  const root = await project(t);
  await writeFile(
    path.join(root, 'laws/example.lawspec'),
    `unit budget
function twice (x :: Int8) -> Integer is x + x end function
law square is definition:
  for all (x :: Int8) => twice x * twice x >= 0 end for all
end definition end law
end unit`,
  );
  const configure = async evaluation =>
    writeFile(
      path.join(root, 'lawspec.edn'),
      configEDN({
        manifestVersion: 1,
        languageProfile: '1.0-rc.2',
        sources: ['laws'],
        targets: [],
        verification: {layers: ['exhaustive'], evaluation},
      }),
    );
  const status = text =>
    JSON.parse(text)
      .evidence.filter(row => row.stage === 'law')
      .map(row => row.status);
  for (const [evaluation, expected] of [
    [{maxSteps: 1}, 'planned'],
    [{maxSteps: 1000000}, 'exhaustively-checked'],
    [{deferLaws: ['budget::square']}, 'planned'],
  ])
  {
    await configure(evaluation);
    const cold = await check(root);
    assert.deepEqual(status(cold), [expected]);
    assert.equal(await check(root), cold);
    assert.equal(await check(root, '--no-cache'), cold);
  }
  for (const evaluation of [
    {maxSteps: 0},
    {maxSteps: -1},
    {maxSteps: 1.5},
    {deferLaws: ['budget::missing']},
  ])
  {
    await configure(evaluation);
    await assert.rejects(check(root));
  }
  await writeFile(
    path.join(root, 'laws/example.lawspec'),
    `unit budget
law vacuous is definition:
  for all (value :: Bool where false) => false end for all
end definition end law
end unit`,
  );
  await configure({deferLaws: ['budget::vacuous']});
  const empty = await check(root);
  assert.deepEqual(status(empty), ['incomplete']);
  assert.equal(await check(root), empty);
  assert.equal(await check(root, '--no-cache'), empty);
});
