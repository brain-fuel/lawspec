// Generated from templates/npm/test/ci-artifact-key.test.mjs by lawspec-dev generate. Do not edit.
import test from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, writeFile, readFile, rm, chmod} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {artifactKey} from '../../tools/ci-artifact-key.mjs';

test('parity keys bind actual compiler, SDK dependency and runtime inputs', async () =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-artifact-key-'));
  try
  {
    const sdk = path.join(root, 'npm');
    await mkdir(path.join(sdk, 'bin'), {recursive: true});
    await mkdir(path.join(sdk, 'test'));
    await mkdir(path.join(root, 'test/fixtures/beam'), {recursive: true});
    await writeFile(
      path.join(sdk, 'api.mjs'),
      'export const checked = true;\n',
    );
    await writeFile(
      path.join(sdk, 'core.wasm'),
      Buffer.from([0, 97, 115, 109]),
    );
    const manifestPath = path.join(sdk, 'package.json');
    const manifest = {name: 'lawspec-key-fixture', version: '0.0.1'};
    await writeFile(manifestPath, JSON.stringify(manifest));
    const native = path.join(root, 'native-core');
    await writeFile(native, 'native compiler one');
    const options = {root, nativeCompiler: native};
    const parity = await artifactKey('parity', options);
    await writeFile(
      path.join(root, 'test/fixtures/beam/schedule.exs'),
      'new scheduling assertions\n',
    );
    await writeFile(
      path.join(sdk, 'test/assertions.mjs'),
      'new unshipped assertions\n',
    );
    await writeFile(path.join(root, 'README.md'), 'new public documentation\n');
    assert.deepEqual(await artifactKey('parity', options), parity);
    await writeFile(
      path.join(sdk, 'api.mjs'),
      'export const checked = false;\n',
    );
    assert.notDeepEqual(await artifactKey('parity', options), parity);
    const beforeWasm = await artifactKey('parity', options);
    await writeFile(
      path.join(sdk, 'core.wasm'),
      Buffer.from([0, 97, 115, 109, 1]),
    );
    assert.notDeepEqual(await artifactKey('parity', options), beforeWasm);
    const beforeNative = await artifactKey('parity', options);
    await writeFile(native, 'native compiler two');
    assert.notDeepEqual(await artifactKey('parity', options), beforeNative);
    const beforeFlags = await artifactKey('parity', options);
    for (const settings of [
      {GHCRTS: '-K64k'},
      {NODE_OPTIONS: '--no-warnings'},
      {NODE_ENV: 'production'},
    ])
      assert.notDeepEqual(
        await artifactKey('parity', {
          ...options,
          environment: {...process.env, ...settings},
        }),
        beforeFlags,
      );
    manifest.dependencies = {'lawspec-key-dependency': '1.0.0'};
    await writeFile(manifestPath, JSON.stringify(manifest));
    const dependency = path.join(sdk, 'node_modules/lawspec-key-dependency');
    await mkdir(dependency, {recursive: true});
    await writeFile(
      path.join(dependency, 'package.json'),
      JSON.stringify({
        name: 'lawspec-key-dependency',
        version: '1.0.0',
        main: 'index.js',
      }),
    );
    await writeFile(path.join(dependency, 'index.js'), 'module.exports = 1;');
    const beforeDependency = await artifactKey('parity', options);
    await writeFile(path.join(dependency, 'index.js'), 'module.exports = 2;');
    const afterDependency = await artifactKey('parity', options);
    assert.equal(afterDependency.sdk, beforeDependency.sdk);
    assert.notEqual(afterDependency.context, beforeDependency.context);
    await assert.rejects(
      artifactKey('package-smoke', options),
      /no certified reusable artifact context/,
    );
  }
  finally
  {
    await rm(root, {recursive: true, force: true});
  }
});

const posixFixture = {
  skip:
    process.platform === 'win32' &&
    'fake toolchain executables use POSIX scripts',
};
const shellQuote = value => "'" + value.replaceAll("'", "'\\''") + "'";
async function compilerFixture(t)
{
  const root = await mkdtemp(
    path.join(os.tmpdir(), 'lawspec compiler context '),
  );
  t.after(() => rm(root, {recursive: true, force: true}));
  const sdk = path.join(root, 'npm'),
    bin = path.join(root, 'tools');
  await mkdir(path.join(sdk, 'bin'), {recursive: true});
  await mkdir(bin);
  await writeFile(
    path.join(sdk, 'package.json'),
    JSON.stringify({name: 'compiler-context-fixture', version: '1'}),
  );
  await writeFile(
    path.join(sdk, 'component.mjs'),
    'export const manifest=1;\n',
  );
  await writeFile(path.join(sdk, 'core.wasm'), Buffer.from([0, 97, 115, 109]));
  await writeFile(path.join(sdk, 'core_jsffi.js'), 'export const ffi=1;\n');
  const paths = Object.fromEntries(
    ['node', 'python3', 'stack', 'ghc', 'z3'].map(name => [
      name,
      path.join(bin, name),
    ]),
  );
  const script = async (name, body) =>
  {
    await writeFile(paths[name], '#!/bin/sh\n' + body + '\n');
    await chmod(paths[name], 0o755);
  };
  const version = async (name, value, suffix = '') =>
    script(name, "printf '%s\\n' " + shellQuote(value) + '\n' + suffix);
  await version('node', 'v22.0.0');
  await version('python3', 'Python 3.14.0');
  await version('ghc', '9.10.3');
  const selection = path.join(root, 'selected-ghc');
  await writeFile(selection, paths.ghc + '\n');
  const stackBody = `case "$1" in
--version) printf '%s\\n' 'stack 3.7.1';;
path) [ "$2" = '--compiler-exe' ] || exit 12; IFS= read -r compiler < ${shellQuote(selection)}; printf '%s\\n' "$compiler";;
*) exit 13;;
esac`;
  await script('stack', stackBody);
  const options = {root, environment: {PATH: bin}};
  return {
    root,
    sdk,
    paths,
    script,
    version,
    stackBody,
    selection,
    options,
    key: extra => artifactKey('compiler-tests', {...options, ...extra}),
  };
}

test(
  'compiler test context records optional Z3 absence and newly available solver bytes',
  posixFixture,
  async t =>
  {
    const f = await compilerFixture(t),
      absent = await f.key();
    assert.deepEqual(await f.key(), absent);
    // The Hspec suite needs no installed lawspec-core executable.
    assert.deepEqual(
      await f.key({nativeCompiler: path.join(f.root, 'missing-native-core')}),
      absent,
    );
    await f.version('z3', 'Z3 version 4.15.0');
    const installed = await f.key();
    assert.notEqual(installed.tools, absent.tools);
    await f.version(
      'z3',
      'Z3 version 4.15.0',
      '# same version, changed implementation',
    );
    const replaced = await f.key();
    assert.notEqual(replaced.tools, installed.tools);
    await rm(f.paths.z3);
    assert.deepEqual(await f.key(), absent);
  },
);

test(
  'compiler test context binds required executable bytes and the Stack-selected GHC',
  posixFixture,
  async t =>
  {
    const f = await compilerFixture(t);
    for (const [name, value] of [
      ['node', 'v22.0.0'],
      ['python3', 'Python 3.14.0'],
      ['ghc', '9.10.3'],
    ])
    {
      const before = await f.key();
      await f.version(name, value, '# implementation replacement');
      assert.notEqual(
        (await f.key()).tools,
        before.tools,
        name + ' replacement must invalidate',
      );
    }
    const beforeStack = await f.key();
    await f.script('stack', f.stackBody + '\n# implementation replacement');
    assert.notEqual((await f.key()).tools, beforeStack.tools);
    const beforeSelection = await f.key();
    const other = path.join(f.root, 'other-ghc');
    await writeFile(other, "#!/bin/sh\nprintf '%s\\n' '9.10.3'\n");
    await chmod(other, 0o755);
    await writeFile(f.selection, other + '\n');
    assert.notEqual((await f.key()).tools, beforeSelection.tools);
  },
);

test(
  'compiler test context binds effective flags, explicit solver selection and empty overrides',
  posixFixture,
  async t =>
  {
    const f = await compilerFixture(t),
      before = await f.key();
    for (const flags of [
      {GHCRTS: '-M64m'},
      {HSPEC_OPTIONS: '--match pending'},
      {NODE_OPTIONS: '--no-warnings'},
      {LAWSPEC_CONTRACT_SOURCE: '1'},
      {LANG: 'C.UTF-8'},
    ])
      assert.notEqual(
        (await f.key({environment: {...f.options.environment, ...flags}}))
          .context,
        before.context,
      );
    await f.version('z3', 'Z3 version 4.15.0');
    const configured = {...f.options.environment, LAWSPEC_Z3: f.paths.z3};
    const first = await f.key({environment: configured});
    const other = path.join(f.root, 'another-z3');
    await writeFile(other, "#!/bin/sh\nprintf '%s\\n' 'Z3 version 4.15.0'\n");
    await chmod(other, 0o755);
    assert.notDeepEqual(
      await f.key({environment: {...configured, LAWSPEC_Z3: other}}),
      first,
    );
    await assert.rejects(
      f.key({environment: {...configured, LAWSPEC_Z3: ''}}),
      /Empty compiler-test tool selection/,
    );
    await assert.rejects(
      f.key({
        environment: {
          ...configured,
          LAWSPEC_Z3: path.join(f.root, 'missing-z3'),
        },
      }),
      /unavailable/,
    );
  },
);

test(
  'compiler test identity failures throw instead of certifying a cached pass or missing solver',
  posixFixture,
  async t =>
  {
    const f = await compilerFixture(t);
    for (const name of ['node', 'python3', 'stack', 'ghc'])
    {
      const original = await readFile(f.paths[name], 'utf8');
      await f.script(name, 'exit 1');
      await assert.rejects(f.key(), /probe failed/);
      await writeFile(f.paths[name], original);
    }
    await f.script('z3', 'exit 1');
    await assert.rejects(f.key(), /probe failed/);
    await chmod(f.paths.z3, 0o644);
    await assert.rejects(f.key(), {code: 'EACCES'});
    await rm(f.paths.z3);
    await f.script('ghc', 'exit 0');
    await assert.rejects(f.key(), /probe was empty/);
    await f.version('ghc', '9.10.3');
    await rm(f.paths.python3);
    await assert.rejects(f.key(), /unavailable/);
    await f.version('python3', 'Python 3.14.0');
    await f.script('stack', "printf '%s\\n' 'first-ghc' 'second-ghc'");
    await assert.rejects(f.key(), /identify one selected GHC/);
  },
);

test(
  'compiler tests bind the SDK WASM and installed dependency closure',
  posixFixture,
  async t =>
  {
    const f = await compilerFixture(t),
      before = await f.key();
    await writeFile(
      path.join(f.sdk, 'core.wasm'),
      Buffer.from([0, 97, 115, 109, 1]),
    );
    const wasm = await f.key();
    assert.notEqual(wasm.sdk, before.sdk);
    await writeFile(
      path.join(f.sdk, 'component.mjs'),
      'export const manifest=2;\n',
    );
    const module = await f.key();
    assert.notEqual(module.sdk, wasm.sdk);
    await writeFile(
      path.join(f.sdk, 'package.json'),
      JSON.stringify({
        name: 'compiler-context-fixture',
        version: '1',
        dependencies: {reader: '1'},
      }),
    );
    for (const [name, dependencies] of [
      ['reader', {nested: '1'}],
      ['nested', {}],
    ])
    {
      const folder = path.join(f.sdk, 'node_modules', name);
      await mkdir(folder, {recursive: true});
      await writeFile(
        path.join(folder, 'package.json'),
        JSON.stringify({name, version: '1', main: 'index.js', dependencies}),
      );
      await writeFile(path.join(folder, 'index.js'), 'module.exports=1;');
    }
    const installed = await f.key();
    await writeFile(
      path.join(f.sdk, 'node_modules/nested/index.js'),
      'module.exports=2;',
    );
    const changed = await f.key();
    assert.equal(changed.sdk, installed.sdk);
    assert.notEqual(changed.context, installed.context);
  },
);
