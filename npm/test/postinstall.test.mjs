// Generated from templates/npm/test/postinstall.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {copyFile, mkdir, mkdtemp, rm, writeFile} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {fileURLToPath} from 'node:url';
const platform = `${process.platform}-${process.arch}`;
// The kit prepares native artifacts on macOS and glibc Linux only.
const preparable =
  process.platform !== 'linux' ||
  Boolean(process.report.getReport().header.glibcVersionRuntime);
// A package directory holding the script and the chosen parts beside it.
async function installed(
  {component, kit = false, native = false, body = ''},
  run,
)
{
  const root = await mkdtemp(path.join(tmpdir(), 'lawspec-postinstall-test-'));
  try
  {
    await copyFile(
      fileURLToPath(new URL('../postinstall.mjs', import.meta.url)),
      path.join(root, 'postinstall.mjs'),
    );
    await writeFile(path.join(root, 'package.json'), '{"type": "module"}\n');
    if (component)
    {
      await mkdir(path.join(root, 'host-component'));
      await writeFile(
        path.join(root, 'host-component/install.mjs'),
        `import {writeFileSync} from 'node:fs';\nwriteFileSync(new URL('./prepared', import.meta.url), '');\n${body}`,
      );
    }
    for (const [wanted, name] of [
      [kit, 'wasm-platform-kit'],
      [native, `wasm-platform-kit-${platform}`],
    ])
    {
      if (wanted)
      {
        const directory = path.join(root, 'node_modules', name);
        await mkdir(path.join(directory, 'bin'), {recursive: true});
        await writeFile(
          path.join(directory, 'package.json'),
          JSON.stringify({name, version: '0.0.0'}),
        );
        await writeFile(path.join(directory, 'bin/host-sdk-runtime'), '');
      }
    }
    const result = spawnSync(process.execPath, ['postinstall.mjs'], {
      cwd: root,
      encoding: 'utf8',
    });
    await run(result, existsSync(path.join(root, 'host-component/prepared')));
  }
  finally
  {
    await rm(root, {recursive: true, force: true});
  }
}
test('a checkout without host-component installs silently', async () =>
  installed({component: false}, result =>
  {
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout + result.stderr, '');
  }));
test('an installation without wasm-platform-kit passes with a one-line note', async () =>
  installed({component: true}, (result, prepared) =>
  {
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stderr, '');
    assert.match(
      result.stdout,
      /^lawspec: the optional native component runtime is unavailable \(wasm-platform-kit is not installed\)\. The CLI does not need it\.\n$/,
    );
    assert.equal(prepared, false);
  }));
test('an installation without the platform package of wasm-platform-kit passes with a one-line note', async () =>
  installed({component: true, kit: true}, (result, prepared) =>
  {
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trimEnd().split('\n').length, 1);
    assert.ok(
      result.stdout.includes(
        `wasm-platform-kit has no installed package for ${platform}`,
      ),
    );
    assert.equal(prepared, false);
  }));
test(
  'a complete installation runs the component preparation',
  {skip: !preparable && 'the platform kit does not support this C library'},
  async () =>
    installed(
      {component: true, kit: true, native: true},
      (result, prepared) =>
      {
        assert.equal(result.status, 0, result.stderr);
        assert.equal(result.stdout + result.stderr, '');
        assert.equal(prepared, true);
      },
    ),
);
test(
  'a preparation that fails still fails the installation',
  {skip: !preparable && 'the platform kit does not support this C library'},
  async () =>
    installed(
      {
        component: true,
        kit: true,
        native: true,
        body: "throw new Error('Portable component integrity mismatch');\n",
      },
      result =>
      {
        assert.notEqual(result.status, 0);
        assert.match(result.stderr, /Portable component integrity mismatch/);
      },
    ),
);
