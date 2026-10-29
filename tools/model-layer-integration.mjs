// Generated from templates/tools/model-layer-integration.mjs by lawspec-dev generate. Do not edit.
import {parseManifest, writeManifest} from '../npm/component.mjs';
// Exercise independent law/model selection through the public CLI and native runners.
// ref:REQ-progressive-verification ref:DEC-stateful-models-linearizability
import assert from 'node:assert/strict';
import {execFile, spawn} from 'node:child_process';
import {promisify} from 'node:util';
import {
  cp,
  mkdir,
  readFile,
  readdir,
  writeFile,
  rm,
  symlink,
} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const exec = promisify(execFile),
  repo = path.resolve(import.meta.dirname, '..');
const packageRoot = path.resolve(
  process.env.LAWSPEC_NPM_SOURCE ?? path.join(repo, 'npm'),
);
const {templates, programTargets: targets} = await import(
  pathToFileURL(path.join(packageRoot, 'templates.mjs'))
);
const language = process.argv[2];
assert.ok(targets.includes(language), 'Pass a supported target');
const bits = Number(process.env.LAWSPEC_MACHINE_BITS ?? 64),
  minify = process.env.LAWSPEC_MINIFY === '1';
assert.ok([32, 64].includes(bits));
const base = path.join(
  repo,
  '.artifacts/model-layer-integration',
  `${language}-${bits}-${minify}`,
);
await rm(base, {recursive: true, force: true});
await mkdir(base, {recursive: true});
const project = path.join(base, 'project with spaces');
await mkdir(project);
const cli = path.join(packageRoot, 'bin/lawspec.mjs'),
  configPath = path.join(project, 'lawspec.edn');
const env = {...process.env, PYTHONDONTWRITEBYTECODE: '1'};
if (env.LAWSPEC_OFFLINE === '1')
  Object.assign(env, {
    CARGO_NET_OFFLINE: 'true',
    GOPROXY: 'off',
    GOTOOLCHAIN: 'local',
    HEX_OFFLINE: '1',
  });
let step = 0;
async function run(command, args, {pass = true, environment = {}} = {})
{
  console.log(`${language}: ${command} ${args.join(' ')}`);
  let result;
  try
  {
    result = await exec(command, args, {
      cwd: project,
      env: {...env, ...environment},
      timeout: 600000,
      maxBuffer: 32 * 1024 * 1024,
    });
  }
  catch (error)
  {
    result = error;
  }
  const output = (result.stdout ?? '') + (result.stderr ?? '');
  await writeFile(
    path.join(
      base,
      `${String(++step).padStart(2, '0')}-${path.basename(command)}.log`,
    ),
    output,
  );
  assert.ok(!result.killed && !result.signal, output);
  if (pass) assert.equal(result.code ?? 0, 0, output);
  else
    assert.ok(
      Number.isInteger(result.code) && result.code > 0,
      `Expected native failure: ${output}`,
    );
  return {stdout: result.stdout ?? '', output};
}
for (const [name, content] of Object.entries(templates(language, {minify})))
{
  const destination = path.join(project, name);
  await mkdir(path.dirname(destination), {recursive: true});
  await writeFile(destination, content);
}
await cp(path.join(repo, 'acceptance/actors', language, 'files'), project, {
  recursive: true,
});
const target = {language, root: '.'};
if (['python', 'prolog'].includes(language))
  target.python =
    process.env.LAWSPEC_PYTHON_EXECUTABLE ??
    path.join(repo, '.integration', language, '.venv/bin/python');
if (['javascript', 'typescript'].includes(language))
  await symlink(
    path.resolve(
      process.env.LAWSPEC_NODE_MODULES ??
        path.join(repo, '.integration', language, 'node_modules'),
    ),
    path.join(project, 'node_modules'),
  );
if (['kotlin', 'groovy'].includes(language))
  target.gradle = process.env.LAWSPEC_GRADLE ?? 'gradle';
if (language === 'scala') target.scala = process.env.LAWSPEC_SCALA ?? 'scala';
if (language === 'go')
  await run('go', ['mod', 'download', 'pgregory.net/rapid']);
if (language === 'haskell')
  await run('stack', [
    '--no-terminal',
    'build',
    '--test',
    '--only-dependencies',
  ]);
if (['erlang', 'elixir', 'gleam'].includes(language))
{
  const lock = {
    erlang: 'rebar.lock',
    elixir: 'mix.lock',
    gleam: 'manifest.toml',
  }[language];
  await cp(
    path.join(repo, 'test/locks', language, lock),
    path.join(project, lock),
  );
  const dependencies =
    process.env.LAWSPEC_BEAM_DEPENDENCIES ??
    path.join(repo, '.integration', language);
  const folders =
    language === 'erlang'
      ? ['_build/test/lib/proper']
      : language === 'elixir'
        ? ['deps/stream_data', '_build/test/lib/stream_data']
        : ['build/packages'];
  for (const folder of folders)
    if (existsSync(path.join(dependencies, folder)))
    {
      await mkdir(path.dirname(path.join(project, folder)), {recursive: true});
      await cp(path.join(dependencies, folder), path.join(project, folder), {
        recursive: true,
      });
    }
  if (language === 'gleam')
    for (const entry of await readdir(
      path.join(dependencies, 'build/packages'),
      {withFileTypes: true},
    ))
    {
      const folder = path.join('build/dev/erlang', entry.name);
      if (entry.isDirectory() && existsSync(path.join(dependencies, folder)))
      {
        await mkdir(path.dirname(path.join(project, folder)), {
          recursive: true,
        });
        await cp(path.join(dependencies, folder), path.join(project, folder), {
          recursive: true,
        });
      }
    }
}
const source = await readFile(
  path.join(repo, 'test/fixtures/canonical-model-layer-selection.lawspec'),
  'utf8',
);
const before = 'Pair (n + amount) (n + amount)',
  after = 'Pair (n + 2 * amount) (n + 2 * amount)';
assert.equal(source.split(before).length, 2);
const specification = path.join(project, 'laws/actors.lawspec');
await mkdir(path.dirname(specification), {recursive: true});
async function select(layers, content = source)
{
  await writeFile(
    configPath,
    writeManifest(
      {
        manifestVersion: 1,
        component: {name: 'example', version: '0.1.0'},
        languageProfile: '1.0-rc.2',
        machineBits: bits,
        verification: {layers},
        sources: ['laws'],
        targets: [target],
      },
      null,
      2,
    ) + '\n',
  );
  await writeFile(specification, content);
}
async function test(pass = true)
{
  await run(process.execPath, [
    cli,
    'generate',
    ...(minify ? ['--minify'] : []),
  ]);
  const report = path.join(base, `native-${step}.xml`);
  const result = await run(
    process.execPath,
    [
      cli,
      'test',
      '--fresh',
      '--seed',
      '811',
      '--json',
      '--report',
      `junit=${report}`,
      ...(minify ? ['--minify'] : []),
    ],
    {pass},
  );
  if (!pass)
    assert.match(
      await readFile(report, 'utf8'),
      /<failure\b/,
      'The mutant must fail a completed native test',
    );
  const rows = JSON.parse(result.stdout);
  if (!Array.isArray(rows))
  {
    assert.equal(rows.testsExecuted, 0);
    assert.equal(rows.verification.selection, 'no-selected-checks');
    return rows;
  }
  assert.equal(rows.length, 1);
  return rows[0];
}
async function evidence()
{
  return JSON.parse(
    (await run(process.execPath, [cli, 'evidence', '--json'])).stdout,
  );
}
const optional = rows =>
  rows.filter(item =>
    ['model', 'linearizable', 'restart', 'scenario', 'supervision'].includes(
      item.stage,
    ),
  );
// An incorrect reference transition is a valid total definition. It must not
// cause optional model execution when only the independent actor laws are selected.
await select(['property', 'examples'], source.replace(before, after));
const laws = await test();
assert.ok(laws.ok, JSON.stringify(laws));
assert.equal(laws.ran.length, 2);
assert.ok(
  laws.ran.every(
    id => !id.includes('::model::') && !id.endsWith('::supervision'),
  ),
);
const views = [];
// Every register words the same law; dev also shows the recorded native
// conformance, which lawspec evidence reports with the law's status.
for (const view of ['eng', 'math', 'dev'])
{
  const rows = JSON.parse(
    (
      await run(process.execPath, [
        cli,
        'explain',
        laws.ran[0].replace('::law::', '::'),
        '--view',
        view,
        '--json',
      ])
    ).stdout,
  );
  assert.equal(rows.length, 1);
  assert.equal(rows[0].view, view);
  views.push(rows[0]);
}
assert.ok(views.every(view => view.law === views[0].law));
assert.match(
  views
    .find(view => view.view === 'dev')
    .sections.find(section => section.kind === 'native-evidence')
    .lines.join('\n'),
  /Native conformance: passed/,
);
assert.ok(
  !views
    .filter(view => view.view !== 'dev')
    .some(view =>
      view.sections.some(section => section.kind === 'native-evidence'),
    ),
);
await select(['model']);
const models = await test();
assert.ok(models.ok, JSON.stringify(models));
assert.equal(models.ran.length, 5);
assert.ok(
  models.ran.every(
    id => id.includes('::model::') || id.endsWith('::supervision'),
  ),
);
const verified = optional(await evidence());
assert.equal(verified.length, 6);
for (const item of verified)
{
  assert.equal(item.status, 'property-tested', JSON.stringify(item));
  assert.equal(item.nativeEvidence.status, 'passed');
  assert.equal(item.nativeEvidence.searchCompleteness, 'not-established');
  assert.ok(
    item.nativeEvidence.observations.every(
      row => row.freshness === 'matching-inputs' && row.attempt.seed === 811,
    ),
  );
}
await select(['model'], source.replace(before, after));
const stale = optional(await evidence());
for (const item of stale)
{
  assert.equal(item.status, 'planned');
  assert.equal(item.nativeEvidence.status, 'stale');
}
const failed = await test(false);
assert.equal(failed.ok, false);
assert.ok(
  failed.ran.some(id => id.includes('::model::account::')),
  JSON.stringify(failed),
);
const rejected = optional(await evidence());
const account = rejected.filter(
  item => item.declaration === 'example.actors::model::account',
);
assert.equal(account.length, 3);
for (const item of account)
{
  assert.equal(item.status, 'incomplete');
  const combined = item.nativeEvidence.observations.some(
    row => (row.attempt?.check.nativeGroup.length ?? 0) > 1,
  );
  assert.equal(item.nativeEvidence.status, combined ? 'incomplete' : 'failed');
}
const supervised = rejected.find(item => item.stage === 'supervision');
assert.equal(
  supervised.nativeEvidence.status,
  'passed',
  'An independently completed supervision check remains valid',
);
await select(['model']);
const repairedBefore = optional(await evidence());
assert.ok(
  repairedBefore.every(item => item.nativeEvidence.status === 'stale'),
  'Restored source does not reuse a pre-failure success',
);
const repaired = await test();
assert.ok(repaired.ok);
assert.ok(
  optional(await evidence()).every(
    item => item.nativeEvidence.status === 'passed',
  ),
);

await select([]);
const none = await test();
assert.equal(none.testsExecuted, 0);
for (const item of optional(await evidence()))
{
  assert.equal(item.status, 'not-verified');
  assert.equal(item.nativeEvidence.status, 'not-selected');
}
await select(['examples']);
const empty = await test();
assert.equal(empty.testsExecuted, 0);
assert.deepEqual(empty.ran, []);
let interrupted, setupFailure, invalidObservation, harnessReplay;
if (language === 'javascript')
{
  // Reusing the exact pre-interruption sources must not resurrect their older
  // passing cache entry. Wait for native module evaluation before interrupting.
  await select(['model']);
  await test();
  const adapter = path.join(project, 'src/example/actors.mjs');
  const implementation = await readFile(adapter, 'utf8');
  const marker = path.join(project, '.lawspec/native-awaiting');
  await writeFile(
    adapter,
    `await (await import('node:fs/promises')).writeFile(${JSON.stringify(marker)},'ready');\n` +
      `await new Promise(resolve=>setTimeout(resolve,600000));\n` +
      implementation,
  );
  const child = spawn(
    process.execPath,
    [
      cli,
      'test',
      '--fresh',
      '--seed',
      '811',
      '--json',
      ...(minify ? ['--minify'] : []),
    ],
    {
      cwd: project,
      env,
      detached: true,
      stdio: 'ignore',
    },
  );
  const stopped = new Promise((resolve, reject) =>
  {
    child.once('exit', resolve);
    child.once('error', reject);
  });
  try
  {
    const deadline = Date.now() + 60000;
    while (
      !existsSync(marker) &&
      Date.now() < deadline &&
      child.exitCode === null
    )
      await new Promise(resolve => setTimeout(resolve, 50));
    assert.ok(
      existsSync(marker),
      'The native runner must reach its paused module',
    );
  }
  finally
  {
    try
    {
      process.kill(-child.pid, 'SIGTERM');
    }
    catch (error)
    {
      if (error.code !== 'ESRCH') throw error;
    }
    await stopped;
    await writeFile(adapter, implementation);
  }
  const resultFiles = (
    await readdir(path.join(project, '.lawspec/results'))
  ).filter(name => name.endsWith('.json'));
  assert.equal(resultFiles.length, 1);
  const pending = JSON.parse(
    await readFile(
      path.join(project, '.lawspec/results', resultFiles[0]),
      'utf8',
    ),
  );
  for (const id of models.ran)
  {
    assert.equal(
      pending.laws[id],
      undefined,
      'An interrupted fresh attempt must remove the old cached pass',
    );
    assert.equal(pending.attempts[id].outcome, 'incomplete');
  }
  interrupted = optional(await evidence());
  assert.ok(
    interrupted.every(
      item =>
        ['planned', 'incomplete'].includes(item.status) &&
        ['stale', 'incomplete'].includes(item.nativeEvidence.status),
    ),
  );
  await test();
  await writeFile(
    adapter,
    "throw new Error('native setup deliberately failed before any model check');\n" +
      implementation,
  );
  await run(
    process.execPath,
    [
      cli,
      'test',
      '--fresh',
      '--seed',
      '811',
      '--json',
      ...(minify ? ['--minify'] : []),
    ],
    {pass: false},
  );
  setupFailure = optional(await evidence());
  assert.ok(
    setupFailure.every(
      item =>
        item.status === 'incomplete' &&
        item.nativeEvidence.status === 'incomplete',
    ),
  );
  assert.ok(
    setupFailure.every(item =>
      item.nativeEvidence.observations.some(row =>
        row.attempt.invocation.output?.includes(
          'native setup deliberately failed',
        ),
      ),
    ),
  );
  await writeFile(adapter, implementation);
  await test();
  assert.ok(
    optional(await evidence()).every(
      item => item.nativeEvidence.status === 'passed',
    ),
  );
  const resultsFile = path.join(project, '.lawspec/results', resultFiles[0]);
  const originalResults = await readFile(resultsFile, 'utf8');
  const damaged = JSON.parse(originalResults);
  damaged.attempts[models.ran[0]].seed = 9007199254740992;
  await writeFile(resultsFile, JSON.stringify(damaged));
  invalidObservation = optional(await evidence());
  assert.ok(
    invalidObservation.some(item =>
      item.nativeEvidence.observations.some(
        row =>
          row.check.id === models.ran[0] && row.freshness === 'unavailable',
      ),
    ),
  );
  await writeFile(resultsFile, originalResults);
  // Exercise consumption of the existing result-file harness metadata. The
  // fixture supplies a prior retry observation; it does not simulate a proof.
  await select(['property']);
  const ordinary = await test();
  const recorded = JSON.parse(await readFile(resultsFile, 'utf8'));
  const id = ordinary.ran[0];
  const adequacy = [
    {
      test: 'generated',
      cases: 20,
      cover: [{label: 'credit', required: 40, observed: 50, met: true}],
    },
  ];
  recorded.laws[id].flaky = true;
  recorded.laws[id].adequacy = adequacy;
  await writeFile(resultsFile, JSON.stringify(recorded));
  harnessReplay = (await evidence()).find(item => item.declaration === id);
  assert.equal(harnessReplay.status, 'flaky');
  assert.deepEqual(harnessReplay.adequacy, adequacy);
  for (const view of ['eng', 'math', 'dev'])
  {
    const rows = JSON.parse(
      (
        await run(process.execPath, [
          cli,
          'explain',
          id.replace('::law::', '::'),
          '--view',
          view,
          '--json',
        ])
      ).stdout,
    );
    assert.equal(rows[0].view, view);
    assert.equal(rows[0].law, id);
  }
}
await writeFile(
  path.join(base, 'receipt.json'),
  JSON.stringify(
    {
      language,
      bits,
      minify,
      laws,
      models,
      failed,
      none,
      verified,
      rejected,
      empty,
      views,
      stale,
      repaired,
      interrupted,
      setupFailure,
      invalidObservation,
      harnessReplay,
    },
    null,
    2,
  ) + '\n',
);
console.log(
  `PASS ${language}: independent actor laws, five model checks, rejected reference mutant, no selected checks`,
);
