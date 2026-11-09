// Generated from templates/component/test/package.test.mjs by lawspec-dev generate. Do not edit.
// The public npm package consumes packed SDK artifacts without developer toolchains.
// ref:DEC-host-sdk-independent-consumer
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {createReadStream} from 'node:fs';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {
  mkdtemp,
  mkdir,
  readFile,
  writeFile,
  symlink,
  rm,
} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
/** Captures installation results from a real clean consumer. ref:REQ-host-sdk-runtime-boundary */
const exec = promisify(execFile);
/** Locates packed application artifacts without using SDK source imports. ref:REQ-host-sdk-runtime-boundary */
const root = path.resolve(import.meta.dirname, '../..');
test(
  'packed LawSpec retains its default API and explicitly runs the SDK without a compiler',
  // Includes prebuilt and source installation plus missing-package controls.
  // Each execution below keeps its own deadline; guest limits are unchanged.
  {timeout: 1080000},
  async t =>
  {
    const temp = await mkdtemp(path.join(tmpdir(), 'lawspec-sdk-install-'));
    t.after(() => rm(temp, {recursive: true, force: true}));
    // Cross-platform acceptance can install the exact archive built on the build
    // host, without spending consumer time recompressing the application.
    const prepared = process.env.LAWSPEC_TEST_PACKAGE;
    const packed = prepared
      ? JSON.parse(await readFile(prepared, 'utf8'))
      : JSON.parse(
          (
            await exec(
              'npm',
              [
                'pack',
                '--ignore-scripts',
                '--json',
                '--pack-destination',
                temp,
              ],
              {cwd: path.join(root, 'npm'), maxBuffer: 4 * 1024 * 1024},
            )
          ).stdout,
        )[0];
    const packageFile = prepared
      ? path.resolve(path.dirname(prepared), packed.filename)
      : path.join(temp, packed.filename);
    const digest = createHash('sha512');
    for await (const chunk of createReadStream(packageFile))
      digest.update(chunk);
    assert.equal('sha512-' + digest.digest('base64'), packed.integrity);
    assert.ok(
      packed.files.some(file => file.path === 'host-component/component.wasm'),
    );
    assert.ok(
      packed.files.some(
        file => file.path === 'host-component/node-registration.mjs',
      ),
    );
    assert.ok(!packed.files.some(file => file.path.endsWith('.cwasm')));
    const nativePackages = JSON.parse(
      await readFile(path.join(root, 'component/native-packages.json'), 'utf8'),
    );
    const nativePackage = nativePackages[`${process.platform}-${process.arch}`];
    assert.ok(nativePackage, 'current platform native package is required');
    const artifacts = JSON.parse(
      await readFile(path.join(root, 'component/sdk-packages.json'), 'utf8'),
    );
    const selected = {
      runtime: artifacts.runtime,
      platform:
        artifacts.platforms?.[`${process.platform}-${process.arch}`] ??
        artifacts.platform,
    };
    const sdkFiles = ['runtime', 'platform'].map(key =>
      path.join(
        root,
        'component/vendor',
        selected[key].file.replace(
          '.tgz',
          `-${selected[key].shasum.slice(0, 12)}.tgz`,
        ),
      ),
    );
    await mkdir(path.join(temp, 'bin'));
    await symlink(process.execPath, path.join(temp, 'bin/node'));
    await writeFile(
      path.join(temp, 'package.json'),
      '{"type":"module","private":true}',
    );
    const npm = (await exec('which', ['npm'])).stdout.trim();
    await exec(
      npm,
      [
        'install',
        '--offline',
        '--script-shell=/bin/sh',
        '--no-audit',
        '--no-fund',
        ...sdkFiles,
        path.join(root, 'component/vendor', nativePackage.file),
        packageFile,
      ],
      {
        cwd: temp,
        env: {PATH: path.join(temp, 'bin'), HOME: process.env.HOME},
        maxBuffer: 4 * 1024 * 1024,
      },
    );
    await writeFile(
      path.join(temp, 'smoke.mjs'),
      `import assert from 'node:assert/strict';
import {createCompiler} from 'lawspec';
const input={languageProfile:'1.0-rc.2',target:'python',verification:{layers:[]},sources:[{path:'a.lawspec',content:'unit a\\nfunction id (x :: Int32) -> Int32 is x end function\\nend unit\\n'}]};
const legacy=await createCompiler();
const component=await createCompiler({runtime:'component'});
const result=await component.check(input);
assert.deepEqual(result.diagnostics,[]);
console.log('component initialized and checked');
for (const method of ['prelude','check','format','expand','inspect','planGeneration','proofTasks','explain','advise']) {
 const request=method==='prelude'?{query:'Bool'}:input;
 assert.deepEqual(await component[method](request),await legacy[method](request),method);
 console.log(method+' parity passed');
}
console.log('packaged compiler passed');
`,
    );
    const result = await exec(process.execPath, ['smoke.mjs'], {
      cwd: temp,
      env: {PATH: path.join(temp, 'bin')},
      timeout: 60000,
      maxBuffer: 1024 * 1024,
    });
    assert.match(result.stdout, /packaged compiler passed/);
    // Source compilation finishes during npm rebuild, never inside createCompiler.
    await rm(
      path.join(temp, `node_modules/${nativePackage.name}/component.cwasm`),
    );
    await exec(
      npm,
      ['rebuild', 'lawspec', '--offline', '--script-shell=/bin/sh'],
      {
        cwd: temp,
        env: {
          PATH: path.join(temp, 'bin'),
          HOME: process.env.HOME,
          WASM_PLATFORM_KIT_BUILD_FROM_SOURCE: '1',
        },
        timeout: 960000,
        maxBuffer: 4 * 1024 * 1024,
      },
    );
    await rm(
      path.join(
        temp,
        `node_modules/wasm-platform-kit-${process.platform}-${process.arch}/bin/host-sdk-source-runtime`,
      ),
    );
    const sourceResult = await exec(process.execPath, ['smoke.mjs'], {
      cwd: temp,
      env: {PATH: path.join(temp, 'bin')},
      timeout: 60000,
      maxBuffer: 1024 * 1024,
    });
    assert.match(sourceResult.stdout, /packaged compiler passed/);
    await rm(path.join(temp, 'node_modules/lawspec/host-component/.native'), {
      recursive: true,
      force: true,
    });
    const missingNative = await exec(process.execPath, ['smoke.mjs'], {
      cwd: temp,
      env: {PATH: path.join(temp, 'bin')},
      timeout: 30000,
    }).then(
      () => null,
      error => error,
    );
    assert.ok(
      missingNative,
      'runtime must not compile missing native artifacts',
    );
    // An explicitly selected unavailable runtime fails; the default API still works.
    await rm(
      path.join(
        temp,
        `node_modules/wasm-platform-kit-${process.platform}-${process.arch}`,
      ),
      {
        recursive: true,
        force: true,
      },
    );
    await writeFile(
      path.join(temp, 'missing.mjs'),
      `import assert from 'node:assert/strict';
import {createCompiler} from 'lawspec';
const component=await createCompiler({runtime:'component'});
await assert.rejects(component.prelude({}),error=>error.code==='unsupported');
const legacy=await createCompiler();
assert.ok(await legacy.prelude({}));
console.log('missing runtime is explicit');
`,
    );
    const missing = await exec(process.execPath, ['missing.mjs'], {
      cwd: temp,
      env: {PATH: path.join(temp, 'bin')},
      timeout: 60000,
      maxBuffer: 1024 * 1024,
    });
    assert.match(missing.stdout, /missing runtime is explicit/);
    await rm(path.join(temp, 'node_modules/wasm-platform-kit'), {
      recursive: true,
      force: true,
    });
    await writeFile(
      path.join(temp, 'absent.mjs'),
      `import assert from 'node:assert/strict';
import {createCompiler} from 'lawspec';
await assert.rejects(createCompiler({runtime:'component'}), error=>error.code==='unsupported');
const legacy=await createCompiler();
assert.ok(await legacy.prelude({}));
console.log('missing SDK is explicit');
`,
    );
    const absent = await exec(process.execPath, ['absent.mjs'], {
      cwd: temp,
      env: {PATH: path.join(temp, 'bin')},
      timeout: 60000,
      maxBuffer: 1024 * 1024,
    });
    assert.match(absent.stdout, /missing SDK is explicit/);
  },
);
