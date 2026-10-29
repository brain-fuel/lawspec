import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {
  mkdtemp,
  mkdir,
  writeFile,
  readFile,
  readdir,
  copyFile,
  rm,
  symlink,
} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath, pathToFileURL} from 'node:url';
import {writeManifest} from '../component.mjs';
import {templates} from '../templates.mjs';

const root = fileURLToPath(new URL('../..', import.meta.url));
const dependencies = path.join(root, '.integration/javascript/node_modules');
const execute = promisify(execFile);

test(
  'CLI execution and evidence include sibling declared inputs without rerunning pure laws',
  {
    skip:
      !existsSync(path.join(dependencies, 'fast-check/package.json')) &&
      'JavaScript test dependencies are not installed',
  },
  async t =>
  {
    const workspace = await mkdtemp(
      path.join(os.tmpdir(), 'lawspec-declared-native-'),
    );
    t.after(() => rm(workspace, {recursive: true, force: true}));
    const component = path.join(workspace, 'component'),
      native = path.join(component, 'native'),
      server = path.join(workspace, 'server');
    const sdk = path.join(workspace, 'sdk');
    await mkdir(path.join(sdk, 'bin'), {recursive: true});
    for (const entry of await readdir(path.join(root, 'npm'), {
      withFileTypes: true,
    }))
      if (entry.isFile())
      {
        const source = path.join(root, 'npm', entry.name),
          destination = path.join(sdk, entry.name);
        if (entry.name === 'core.wasm') await symlink(source, destination);
        else await copyFile(source, destination);
      }
    for (const entry of await readdir(path.join(root, 'npm/bin')))
      await copyFile(
        path.join(root, 'npm/bin', entry),
        path.join(sdk, 'bin', entry),
      );
    await symlink(
      path.join(root, 'npm/node_modules'),
      path.join(sdk, 'node_modules'),
      'dir',
    );
    await Promise.all([
      mkdir(path.join(component, 'laws'), {recursive: true}),
      mkdir(native, {recursive: true}),
      mkdir(server),
    ]);
    await symlink(dependencies, path.join(native, 'node_modules'), 'dir');
    for (const [file, content] of Object.entries(templates('javascript')))
    {
      await mkdir(path.dirname(path.join(native, file)), {recursive: true});
      await writeFile(path.join(native, file), content);
    }
    const manifest = path.join(component, 'lawspec.edn');
    await writeFile(
      manifest,
      writeManifest({
        manifestVersion: 1,
        component: {name: 'sibling-cache', version: '0.1.0'},
        languageProfile: '1.0-rc.2',
        verification: {layers: ['property', 'examples']},
        sources: ['laws'],
        targets: [{language: 'javascript', root: 'native'}],
        inputs: ['../server'],
      }),
    );
    await writeFile(
      path.join(component, 'laws/example.lawspec'),
      `unit example
read :: Unit -> Int32
function pureValue (value :: Int8) -> Int8 is value end function
law nativeAnswer is definition: read unitValue = 7 end definition end law
law pureAnswer is definition: for all (value :: Int8) => pureValue value = value end for all end definition end law
end unit
`,
    );
    const countFile = path.join(workspace, 'executions.log'),
      implementation = path.join(server, 'implementation.mjs');
    const writeImplementation = (value, comment = '') =>
      writeFile(
        implementation,
        `import {appendFileSync} from 'node:fs';\nexport function read(){appendFileSync(${JSON.stringify(countFile)},'called\\n');return ${value};}\n${comment}\n`,
      );
    await writeImplementation(7);
    const cli = async (verb, ok = true) =>
    {
      try
      {
        const result = await execute(
          process.execPath,
          [
            path.join(sdk, 'bin/lawspec.mjs'),
            verb,
            '--config',
            manifest,
            '--json',
            ...(verb === 'test' ? ['--seed', '73'] : []),
          ],
          {cwd: component, maxBuffer: 16 * 1024 * 1024, timeout: 60000},
        );
        assert.equal(ok, true, result.stderr);
        return JSON.parse(result.stdout);
      }
      catch (error)
      {
        if (ok) throw error;
        assert.equal(error.code, 1, error.stderr);
        return JSON.parse(error.stdout);
      }
    };
    await cli('generate');
    await writeFile(
      path.join(native, 'src/example.mjs'),
      `export {read} from ${JSON.stringify(pathToFileURL(implementation).href)};\n`,
    );
    const first = await cli('test');
    assert.equal(first[0].ok, true);
    assert.equal(first[0].ran.length, 2);
    const described = await cli('describe');
    const executions = () => readFile(countFile, 'utf8');
    const initial = await executions();
    assert.ok(initial.length > 0);
    const unchanged = await cli('test');
    assert.deepEqual(unchanged[0].ran, []);
    assert.equal(await executions(), initial);
    for (const directory of [
      'target',
      'bin',
      'obj',
      '.lawspec',
      'build',
      'dist',
    ])
    {
      await mkdir(path.join(server, directory));
      await writeFile(
        path.join(server, directory, 'generated'),
        'build output',
      );
    }
    const rebuilt = await cli('test');
    assert.deepEqual(rebuilt[0].ran, []);
    assert.equal(await executions(), initial);
    assert.equal((await cli('describe')).fingerprint, described.fingerprint);
    await writeImplementation(7, '// external implementation edit');
    assert.notEqual((await cli('describe')).fingerprint, described.fingerprint);
    const evidence = await cli('evidence');
    const rows = Array.isArray(evidence) ? evidence : evidence.evidence;
    const nativeEvidence = rows.find(row =>
      row.declaration.endsWith('nativeAnswer'),
    ).nativeEvidence;
    const pureEvidence = rows.find(row =>
      row.declaration.endsWith('pureAnswer'),
    ).nativeEvidence;
    assert.equal(nativeEvidence.observations[0].freshness, 'stale');
    assert.equal(pureEvidence.observations[0].freshness, 'matching-inputs');
    assert.equal(
      await executions(),
      initial,
      'evidence must not execute native tests',
    );
    const edited = await cli('test');
    assert.equal(edited[0].ran.length, 1);
    assert.match(edited[0].ran[0], /nativeAnswer$/);
    assert.equal(edited[0].unchanged, 1);
    assert.ok((await executions()).length > initial.length);
    const repeated = await executions();
    assert.deepEqual((await cli('test'))[0].ran, []);
    assert.equal(await executions(), repeated);
    const cacheFolders = await readdir(path.join(component, '.lawspec/cache'));
    const hostFile = path.join(sdk, 'test-command.mjs'),
      hostSource = await readFile(hostFile, 'utf8');
    const changedHost = hostSource.replace(
      /export function invocations\(\.\.\.arguments_\)\s*\{/,
      opening =>
        `${opening}\n  if (!Array.isArray(arguments_[1]))\n  {\n    throw new TypeError('Native selection entries must be a list');\n  }`,
    );
    assert.notEqual(changedHost, hostSource);
    await writeFile(hostFile, changedHost);
    const hostEvidence = await cli('evidence'),
      hostRows = Array.isArray(hostEvidence)
        ? hostEvidence
        : hostEvidence.evidence;
    for (const name of ['nativeAnswer', 'pureAnswer'])
    {
      const observation = hostRows.find(row => row.declaration.endsWith(name))
        .nativeEvidence.observations[0];
      assert.equal(observation.freshness, 'unavailable');
      assert.match(
        observation.reason,
        /Current generated presentation has not passed native validation/,
      );
    }
    const hostRun = await cli('test');
    assert.equal(hostRun[0].ran.length, 2);
    assert.equal(hostRun[0].unchanged, 0);
    assert.deepEqual(
      await readdir(path.join(component, '.lawspec/cache')),
      cacheFolders,
      'host changes must not change WASM compiler cache mounts',
    );
    const hostExecutions = await executions();
    assert.deepEqual((await cli('test'))[0].ran, []);
    assert.equal(await executions(), hostExecutions);
    await writeImplementation(9);
    const failed = await cli('test', false);
    assert.equal(failed[0].ok, false);
    assert.equal(failed[0].ran.length, 1);
    assert.match(failed[0].ran[0], /nativeAnswer$/);
    assert.equal(failed[0].unchanged, 1);
    assert.ok((await executions()).length > repeated.length);
  },
);
