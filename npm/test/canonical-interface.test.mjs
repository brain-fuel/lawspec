// Generated from templates/npm/test/canonical-interface.test.mjs by lawspec-dev generate. Do not edit.
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp, readFile, readdir, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createCompiler} from '../api.mjs';
const compiler = await createCompiler();
const canonical = {schemaVersion: 5, languageProfile: '1.0-rc.2'};
const sources = content => [
  {
    path: 'boundary.lawspec',
    content: 'unit boundary\n' + content + '\nend unit\n',
  },
];

test('ordinary methods reject unsupported schemas', async () =>
{
  for (const method of [
    'check',
    'expand',
    'planGeneration',
    'format',
    'proofTasks',
  ])
    for (const schemaVersion of [3, 4])
    {
      const result = await compiler[method]({
        ...canonical,
        schemaVersion,
        target: 'python',
        sources: sources(''),
      });
      assert.equal(result.schemaVersion, 5);
      assert.deepEqual(
        result.diagnostics.map(row => row.code),
        ['request'],
      );
      assert.match(result.diagnostics[0].message, /schemaVersion 5/);
    }
});
test('the canonical profile is explicit even when schema 5 is supplied by the SDK', async () =>
{
  for (const languageProfile of [undefined, null, '0.24'])
  {
    const result = await compiler.check({
      languageProfile,
      sources: sources(''),
    });
    assert.deepEqual(
      result.diagnostics.map(row => row.code),
      ['request'],
    );
  }
  assert.deepEqual(
    (await compiler.check({languageProfile: '1.0-rc.2', sources: sources('')}))
      .diagnostics,
    [],
  );
});
test('no selected checks means unverified laws while definition admission remains mandatory', async () =>
{
  const source =
    sources(`law falseClaim is definition: false end definition end law
`);
  const result = await compiler.check({...canonical, sources: source});
  assert.deepEqual(result.diagnostics, []);
  assert.equal(result.verification.selection, 'no-selected-checks');
  assert.equal(result.verification.intrinsicDefinitionChecks, true);
  assert.deepEqual(
    result.evidence.filter(row => row.stage === 'law').map(row => row.status),
    ['not-verified'],
  );
  assert.ok(
    (
      await compiler.check({
        ...canonical,
        sources: source,
        verification: {layers: ['exhaustive']},
      })
    ).diagnostics.length,
  );
  for (const body of [
    `function loops (x of type Integer) -> Integer is loops x end function
`,
    `function unsafe (x of type Integer) -> Integer is prelude.quot x 0 end function
`,
  ])
  {
    const rejected = await compiler.check({
      ...canonical,
      sources: sources(body),
    });
    assert.ok(rejected.diagnostics.length);
    assert.ok(
      rejected.diagnostics.every(
        row => !['request', 'parse'].includes(row.code),
      ),
    );
  }
});
test('legacy declarations and bare endings are rejected by every ordinary entry', async () =>
{
  for (const content of [
    'definition twice (x :: Integer) :: Integer is x + x end',
    'law old is definition: true end end',
  ])
  {
    for (const method of ['check', 'expand', 'format', 'planGeneration'])
    {
      const result = await compiler[method]({
        ...canonical,
        target: 'python',
        sources: sources(content),
      });
      assert.ok(result.diagnostics.length, method);
    }
  }
  assert.equal(compiler.migrationBaseline, undefined);
});
test('native bindings use the canonical schema', async () =>
{
  const result = await compiler.check({
    ...canonical,
    sources: sources('echo of type Int8 -> Int8'),
    nativeBindings: {
      functions: [
        {declaration: 'boundary::echo', native: ['Application', 'echo']},
      ],
    },
  });
  assert.deepEqual(result.diagnostics, []);
  assert.equal(result.schemaVersion, 5);
});

test('the CLI rejects old project configuration before changing files', async t =>
{
  const root = await mkdtemp(path.join(tmpdir(), 'lawspec-interface-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  const config = JSON.stringify({
    version: 1,
    sources: ['boundary.lawspec'],
    targets: [],
  });
  await writeFile(path.join(root, 'lawspec.json'), config);
  await writeFile(path.join(root, 'boundary.lawspec'), sources('')[0].content);
  const before = (await readdir(root)).sort();
  const exec = promisify(execFile),
    cli = new URL('../bin/lawspec.mjs', import.meta.url).pathname;
  for (const args of [
    ['check'],
    ['evidence'],
    ['generate'],
    ['test'],
    ['fmt'],
    ['init', '--target', 'javascript'],
  ])
  {
    await assert.rejects(
      exec(process.execPath, [cli, ...args, '--json'], {cwd: root}),
      error =>
      {
        assert.equal(error.code, 1);
        const result = JSON.parse(error.stdout);
        assert.match(result.diagnostics[0].message, /lawspec.edn/);
        return true;
      },
    );
    assert.deepEqual((await readdir(root)).sort(), before);
    assert.equal(
      await readFile(path.join(root, 'lawspec.json'), 'utf8'),
      config,
    );
  }
  await writeFile(
    path.join(root, 'lawspec.json'),
    JSON.stringify({version: 2, sources: ['boundary.lawspec'], targets: []}),
  );
  await assert.rejects(
    exec(process.execPath, [cli, 'check', '--json'], {cwd: root}),
    error => /lawspec.edn/.test(error.stdout),
  );
});
