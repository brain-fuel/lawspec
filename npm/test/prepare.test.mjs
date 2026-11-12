// Generated from templates/npm/test/prepare.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {spawnSync} from 'node:child_process';
import {mkdtemp, mkdir, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {applyRequirements} from '../prepare.mjs';

const cli = new URL('../bin/lawspec.mjs', import.meta.url).pathname;

async function project(t, files)
{
  const root = await mkdtemp(path.join(tmpdir(), 'lawspec-prepare-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  for (const [name, content] of Object.entries(files))
  {
    await mkdir(path.dirname(path.join(root, name)), {recursive: true});
    await writeFile(path.join(root, name), content);
  }
  return root;
}
const json = async (root, name) =>
  JSON.parse(await readFile(path.join(root, name), 'utf8'));

// What npm init -y followed by npm install lawspec leaves behind.
const npmInit =
  JSON.stringify(
    {
      name: 'consumer',
      version: '1.0.0',
      main: 'index.js',
      scripts: {test: 'echo "Error: no test specified" && exit 1'},
      type: 'commonjs',
      dependencies: {lawspec: '^0.33.0'},
    },
    null,
    4,
  ) + '\n';

test('javascript: an npm init package gains type=module and fast-check, and keeps the rest', async t =>
{
  const root = await project(t, {'package.json': npmInit});
  const result = await applyRequirements('javascript', root);
  assert.deepEqual(result, {
    created: [],
    updated: ['package.json (type, devDependencies.fast-check)'],
  });
  const written = await readFile(path.join(root, 'package.json'), 'utf8');
  assert.deepEqual(JSON.parse(written), {
    ...JSON.parse(npmInit),
    type: 'module',
    devDependencies: {'fast-check': '4.10.2'},
  });
  // The owner's four-space indentation and final newline survive.
  assert.match(written, /^\{\n {4}"name"/);
  assert.ok(written.endsWith('}\n'));
  // A second run has nothing left to add.
  assert.deepEqual(await applyRequirements('javascript', root), {
    created: [],
    updated: [],
  });
});

test('javascript: type=commonjs stays when a source file depends on it', async t =>
{
  const root = await project(t, {
    'package.json': npmInit,
    'lib/server.js': 'module.exports = {};\n',
    'node_modules/dependency/index.js': 'module.exports = {};\n',
  });
  await assert.rejects(
    applyRequirements('javascript', root),
    /type=commonjs and lib\/server\.js depends on it.*--project/s,
  );
  assert.equal(
    await readFile(path.join(root, 'package.json'), 'utf8'),
    npmInit,
  );
});

test('javascript: installed packages alone do not block type=module', async t =>
{
  const root = await project(t, {
    'package.json': npmInit,
    'node_modules/dependency/index.js': 'module.exports = {};\n',
  });
  await applyRequirements('javascript', root);
  assert.equal((await json(root, 'package.json')).type, 'module');
});

test('javascript: dependencies the project already declares are kept', async t =>
{
  const root = await project(t, {
    'package.json': JSON.stringify({
      type: 'module',
      dependencies: {'fast-check': '^4.0.0'},
    }),
  });
  assert.deepEqual(await applyRequirements('javascript', root), {
    created: [],
    updated: [],
  });
  const pinned = await project(t, {
    'package.json': JSON.stringify({
      type: 'module',
      devDependencies: {'fast-check': '4.1.0'},
    }),
  });
  await applyRequirements('javascript', pinned);
  assert.equal(
    (await json(pinned, 'package.json')).devDependencies['fast-check'],
    '4.1.0',
  );
});

test('typescript: a missing tsconfig.json is created and an existing one is left alone', async t =>
{
  const root = await project(t, {'package.json': '{"type": "module"}\n'});
  const result = await applyRequirements('typescript', root);
  assert.deepEqual(result.created, ['tsconfig.json']);
  assert.deepEqual((await json(root, 'package.json')).devDependencies, {
    'fast-check': '4.10.2',
    typescript: '5.9.3',
    '@types/node': '22.20.4',
  });
  assert.equal(
    (await json(root, 'tsconfig.json')).compilerOptions.module,
    'NodeNext',
  );
  // tsconfig.json may hold comments, so an existing one is never parsed.
  const commented = '// ours\n{"compilerOptions": {}}\n';
  const existing = await project(t, {
    'package.json': '{"type": "module"}\n',
    'tsconfig.json': commented,
  });
  assert.deepEqual(
    (await applyRequirements('typescript', existing)).created,
    [],
  );
  assert.equal(
    await readFile(path.join(existing, 'tsconfig.json'), 'utf8'),
    commented,
  );
});

test('csharp: global.json gains the test runner and keeps its SDK pin', async t =>
{
  const root = await project(t, {
    'global.json': '{"sdk": {"version": "10.0.100"}}',
  });
  await applyRequirements('csharp', root);
  assert.deepEqual(await json(root, 'global.json'), {
    sdk: {version: '10.0.100'},
    test: {runner: 'Microsoft.Testing.Platform'},
  });
});

test('a build file that is not JSON is reported, not rewritten', async t =>
{
  const root = await project(t, {'package.json': '{broken'});
  await assert.rejects(
    applyRequirements('javascript', root),
    /package\.json is not valid JSON/,
  );
});

test('targets without JSON requirements change nothing', async t =>
{
  const root = await project(t, {'pom.xml': '<project/>\n'});
  assert.deepEqual(await applyRequirements('java', root), {
    created: [],
    updated: [],
  });
});

const run = (root, args, env = process.env) =>
  spawnSync(process.execPath, [cli, ...args], {
    cwd: root,
    encoding: 'utf8',
    timeout: 60000,
    env,
  });

test('init --no-install updates the build file and runs no tool', async t =>
{
  const root = await project(t, {'package.json': npmInit});
  const result = run(root, ['init', '--no-install', '--target', 'javascript']);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(
    result.stdout,
    /Existing build files preserved; updated package\.json \(type, devDependencies\.fast-check\)\./,
  );
  assert.match(result.stdout, /Next: lawspec doctor, then lawspec generate\./);
  assert.equal((await json(root, 'package.json')).type, 'module');
  await assert.rejects(readFile(path.join(root, 'package-lock.json')));
});

test('init reports a missing build tool and exits 1, keeping the configuration', async t =>
{
  const root = await project(t, {});
  // Only Node is on PATH, so cargo cannot be found.
  const result = run(root, ['init', '--target', 'rust'], {
    ...process.env,
    PATH: path.dirname(process.execPath),
  });
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /rust is not ready: cargo was not found on PATH/);
  assert.match(result.stdout, /Use Rust 1\.85\+/);
  await readFile(path.join(root, 'lawspec.edn'), 'utf8');
  await readFile(path.join(root, 'Cargo.toml'), 'utf8');
});

test('--no-install applies to init only', async t =>
{
  const root = await project(t, {});
  const result = run(root, ['check', '--no-install']);
  assert.equal(result.status, 1);
  assert.match(result.stdout + result.stderr, /--no-install applies to init/);
});
