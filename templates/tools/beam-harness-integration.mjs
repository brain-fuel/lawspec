// Exercise public harness compilation through the actual installed npm archive.
// Native callbacks independently audit selection, skips and benchmarks.
// ref:REQ-harness-units ref:DEC-tests-cite-requirements
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {cp, mkdir, readFile, rm, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

const exec = promisify(execFile), repo = path.resolve(import.meta.dirname, '..');
const language = process.argv[2];
assert.ok(['erlang', 'elixir', 'gleam'].includes(language), 'Pass a BEAM target');
const bits = Number(process.env.LAWSPEC_MACHINE_BITS ?? 64), minify = process.env.LAWSPEC_MINIFY === '1';
assert.ok([32, 64].includes(bits));
const base = path.join(repo, '.artifacts/beam-harness-integration', `${language}-${bits}-${minify}`);
await rm(base, {recursive: true, force: true});
await mkdir(base, {recursive: true});
const project = path.join(base, 'project with spaces');
const env = {...process.env, npm_config_cache: path.join(repo, '.artifacts/npm-cache')};
if (env.LAWSPEC_OFFLINE === '1') env.HEX_OFFLINE = '1';
let step = 0;
async function run(command, args, cwd = project, {pass = true, environment = {}} = {}) {
  console.log(`${language}: ${command} ${args.join(' ')}`);
  let result;
  try { result = await exec(command, args, {cwd, env: {...env, ...environment},
    timeout: 180000, maxBuffer: 16 * 1024 * 1024}); }
  catch (error) { result = error; }
  const output = (result.stdout ?? '') + (result.stderr ?? '');
  await writeFile(path.join(base, `${String(++step).padStart(2, '0')}-${path.basename(command)}.log`), output);
  assert.ok(!result.killed && !result.signal, `Native process did not finish: ${output}`);
  if (pass) assert.equal(result.code ?? 0, 0, output);
  else assert.ok(Number.isInteger(result.code) && result.code > 0, `Expected failed command: ${output}`);
  return {stdout: result.stdout ?? '', output};
}
const packageSource = process.env.LAWSPEC_NPM_SOURCE;
const packed = JSON.parse((await run('npm', ['pack', '--json', '--pack-destination', base,
  ...(packageSource ? ['--ignore-scripts'] : [])], path.resolve(packageSource ?? path.join(repo, 'npm')))).stdout)[0];
const installation = path.join(base, 'installation');
await run('npm', ['install', '--offline', '--ignore-scripts', '--no-audit', '--no-fund',
  '--prefix', installation, path.join(base, packed.filename)], base);
const packageRoot = path.join(installation, 'node_modules/lawspec');
const cli = path.join(packageRoot, 'bin/lawspec.mjs'), configFile = path.join(base, 'lawspec.json');
const layoutFlags = minify ? ['--minify'] : [];
async function call(verb, flags = [], options = {}) {
  const result = await run(process.execPath, [cli, verb, '--config', configFile, ...flags], base, options);
  return {...result, ...(flags.includes('--json') ? {json: JSON.parse(result.stdout)} : {})};
}
await call('init', ['--target', language, '--project', project, '--machine-bits', String(bits), ...layoutFlags]);
const lock = {erlang: 'rebar.lock', elixir: 'mix.lock', gleam: 'manifest.toml'}[language];
await cp(path.join(repo, 'test/locks', language, lock), path.join(project, lock));
const dependencies = process.env.LAWSPEC_BEAM_DEPENDENCIES;
if (dependencies) {
  const folders = language === 'erlang' ? ['_build/test/lib/proper'] :
    language === 'elixir' ? ['deps/stream_data', '_build/test/lib/stream_data'] : ['build/packages'];
  for (const folder of folders) {
    await mkdir(path.dirname(path.join(project, folder)), {recursive: true});
    await cp(path.join(dependencies, folder), path.join(project, folder), {recursive: true});
  }
}
if (language === 'erlang') await run('rebar3', ['as', 'test', 'compile']);
if (language === 'elixir') {
  if (!dependencies) await run('mix', ['deps.get'], project, {environment: {MIX_ENV: 'test'}});
  await run('mix', ['deps.compile'], project, {environment: {MIX_ENV: 'test'}});
}
if (language === 'gleam') await run('gleam', ['build']);
const suites = ['beam-selection', 'beam-strategies', 'beam-adequacy', 'beam-target',
  'beam-repetition', 'beam-benchmarks', 'beam-resource-owners', 'scheduling', 'tables'];
const sources = [];
for (const suite of suites) {
  const manifest = JSON.parse(await readFile(path.join(repo, 'acceptance', suite, 'suite.json'), 'utf8'));
  for (const file of manifest.specs) {
    let content = await readFile(path.join(repo, file), 'utf8');
    if (file === 'acceptance/beam-selection/a.lawspec')
      content = content.replace('  order random\n  parallel', '  order random\n  parallel\n  tags smoke');
    if (suite === 'beam-resource-owners')
      content = content.replace('    timeout 500 ms', '    timeout 500 ms\n    tags owners');
    const source = {path: `${suite}-${path.basename(file)}`, content};
    sources.push(source);
    await writeFile(path.join(base, source.path), source.content);
  }
}
sources.sort((a, b) => a.path.localeCompare(b.path));
const config = JSON.parse(await readFile(configFile, 'utf8'));
config.sources = sources.map(source => source.path);
await writeFile(configFile, JSON.stringify(config, null, 2) + '\n');
await call('generate', ['--json', ...layoutFlags]);
for (const suite of suites)
  for (const kind of ['files', 'native'])
    if (suite !== 'tables' || kind === 'files')
      await cp(path.join(repo, 'acceptance', suite, language, kind), project, {recursive: true});
await cp(path.join(repo, 'acceptance/tables/recorded'), path.join(base, 'recorded'), {recursive: true});
await call('generate', ['--check', ...layoutFlags]);

const {createCompiler} = await import(pathToFileURL(path.join(packageRoot, 'api.mjs')));
const {harnessStatistics} = await import(pathToFileURL(path.join(packageRoot, 'test-command.mjs')));
const {projectKey} = await import(pathToFileURL(path.join(packageRoot, 'failure-database.mjs')));
const compiler = await createCompiler();
const plan = await compiler.planGeneration({target: language, machineBits: bits, minify, sources});
assert.deepEqual(plan.diagnostics, []);
assert.equal(plan.tests.length, 39);
assert.equal(plan.benchmarks.length, 8);
const selectionAudit = path.join(base, 'selection.jsonl');
const benchmarkAudit = path.join(base, 'benchmarks.jsonl');
const environment = {LAWSPEC_SELECTION_AUDIT: selectionAudit, LAWSPEC_BENCHMARK_AUDIT: benchmarkAudit};
const selectedCalls = async () => (await readFile(selectionAudit, 'utf8').catch(() => ''))
  .trim().split('\n').filter(Boolean).map(Number).sort((a, b) => a - b);
const benchmarkCalls = async () => (await readFile(benchmarkAudit, 'utf8').catch(() => ''))
  .trim().split('\n').filter(Boolean).map(row => JSON.parse(row));
const statsPath = path.join(base, '.lawspec/reports', language, projectKey(project), 'statistics');
const test = async (flags = [], options = {}) =>
  call('test', [...flags, '--json', ...layoutFlags], {environment, ...options});

const first = (await test(['--fresh', '--seed', '4201', '--report', 'junit=harness.xml'])).json[0];
assert.ok(first.ok && !first.unrun, JSON.stringify(first));
assert.deepEqual(first.ran, plan.tests.map(test => test.law));
assert.deepEqual(await selectedCalls(), [1, 2, 4, 10, 20, 21]);
assert.ok(first.flaky.includes('example.repetition::transient failure'));
assert.ok(first.parallelism.some(row => row.unit === 'example.overlap' && row.workers === 3));
assert.ok(!first.benchmarks);
assert.deepEqual((await benchmarkCalls()).map(row => row.name), ['ordinary']);
const records = await harnessStatistics(statsPath);
assert.ok(records.some(row => row.law === 'example.selectionB::skipped' && row.outcome === 'skipped'));
assert.ok(records.some(row => row.law === 'example.selectionB::known' && row.outcome === 'known-failing'));
assert.ok(records.some(row => row.law === 'example.adequacy::generated observations' && row.cases === 100
  && row.cover.every(cover => cover.met)));
assert.ok(records.some(row => row.law === 'example.repetition::repeated random cases'
  && row.repeat === 3 && row.runs.length === 3));
assert.ok(records.some(row => row.law === 'example.target::interior maximum' && row.search));
assert.ok(records.some(row => row.law === 'example.resourceOwners::owners release after each test' && row.outcome === 'passed'));
const junit = await readFile(path.join(base, 'harness.xml'), 'utf8');
assert.ok(junit.includes('example.selectionA') && junit.includes('example.selectionB'));
assert.match(junit, /<skipped/);
console.log('PASS public compiler, all harness laws, skip/known-fail, flaky retries, repeat/coverage/search, parallelism and JUnit');

await rm(selectionAudit, {force: true});
await rm(benchmarkAudit, {force: true});
const cached = (await test()).json[0];
assert.ok(cached.ok && cached.ran.length === 0 && cached.unchanged === plan.tests.length, JSON.stringify(cached));
assert.deepEqual(await selectedCalls(), []);
assert.deepEqual(await benchmarkCalls(), []);
const tagged = (await test(['--fresh', '--tag', 'smoke', '--seed', '4201'])).json[0];
assert.ok(tagged.ok && !tagged.unrun, JSON.stringify(tagged));
assert.deepEqual(tagged.ran, plan.tests.filter(row => row.tags.includes('smoke')).map(row => row.law));
assert.deepEqual(await selectedCalls(), [1, 10, 20, 21]);
console.log('PASS unchanged cache and exact public tag selection');

await rm(selectionAudit, {force: true});
for (let pass = 0; pass < 2; pass++) {
  await rm(benchmarkAudit, {force: true});
  const measured = (await test(['--benchmarks'])).json[0];
  assert.ok(measured.ok && measured.ran.length === 0, JSON.stringify(measured));
  assert.deepEqual(measured.benchmarks.map(row => `${row.unit}::${row.benchmark}`).sort(),
    plan.benchmarks.map(row => `${row.unit}::${row.benchmark}`).sort());
  const calls = await benchmarkCalls();
  assert.ok(!calls.some(row => row.name === 'ordinary'));
  const kinds = {'checked adapter': ['sync', 7], 'async adapter': ['async', 8],
    'false is a value': ['false', false], 'production handler': ['production', 1337]};
  for (const row of measured.benchmarks) {
    assert.ok(row.iterations >= 3 && row.mean_ns >= row.min_ns && row.min_ns >= 0);
    if (row.unit !== 'example.benchmarks') continue;
    const [name, value] = kinds[row.benchmark], seen = calls.filter(call => call.name === name);
    assert.equal(seen.length, row.iterations);
    assert.ok(seen.every(call => call.value === value));
  }
  assert.deepEqual(await selectedCalls(), []);
}
console.log('PASS every benchmark executes on each requested run, with exact callback counts and no cached laws rerun');

const helper = path.join(project, 'src/beam_selection_support.erl');
const original = await readFile(helper, 'utf8');
assert.equal(original.split('    N.').length, 2);
await new Promise(resolve => setTimeout(resolve, 1100));
await writeFile(helper, original.replace('    N.', '    case N of 4 -> 5; _ -> N end.'));
try {
  const repairedKnown = await test(['--fresh', '--seed', '811'], {pass: false, environment});
  assert.equal(repairedKnown.json[0].ok, false);
  assert.match(repairedKnown.output, /known_failing_passed|KnownFailingPassed/);
  assert.ok((await harnessStatistics(statsPath)).some(row => row.outcome === 'known-failing-passed'));
} finally {
  await new Promise(resolve => setTimeout(resolve, 1100));
  await writeFile(helper, original);
}
const recovered = (await test()).json[0];
assert.ok(recovered.ok && !recovered.unrun, JSON.stringify(recovered));
console.log('PASS unexpectedly passing known failure is rejected, and restoration replays successfully');

// The CLI owns recording selection and cache invalidation; the native runtime
// owns comparison and the explicit write. Exercise both from the installed package.
const recording = path.join(base, 'recorded/example.tables/first label');
const canonicalRecording = await readFile(path.join(repo, 'acceptance/tables/recorded/example.tables/first label'), 'utf8');
await writeFile(recording, '"stale label"\n');
const stale = await test([], {pass: false, environment});
assert.equal(stale.json[0].ok, false);
assert.match(stale.output, /recorded\/example\.tables\/first label differs/);
assert.equal(await readFile(recording, 'utf8'), '"stale label"\n');
await rm(recording);
const missing = await test([], {pass: false, environment});
assert.equal(missing.json[0].ok, false);
assert.match(missing.output, /no recording recorded\/example\.tables\/first label/);
await assert.rejects(readFile(recording), {code: 'ENOENT'});
const updated = (await test(['--update-recorded'])).json[0];
assert.ok(updated.ok && !updated.unrun, JSON.stringify(updated));
assert.deepEqual(updated.ran, plan.tests.map(test => test.law));
assert.equal(await readFile(recording, 'utf8'), canonicalRecording);
assert.equal(await readFile(path.join(base, 'recorded/example.tables/parcel 42'), 'utf8'),
  await readFile(path.join(repo, 'acceptance/tables/recorded/example.tables/parcel 42'), 'utf8'));
const recordedAgain = (await test()).json[0];
assert.ok(recordedAgain.ok && !recordedAgain.unrun, JSON.stringify(recordedAgain));
const recordedCached = (await test()).json[0];
assert.ok(recordedCached.ok && recordedCached.ran.length === 0 && recordedCached.unchanged === plan.tests.length,
  JSON.stringify(recordedCached));
console.log('PASS stale and missing recordings fail, explicit updates reproduce shared files, and unchanged recordings cache');

// Ownership and cancellation must survive the installed CLI's selection,
// native runner and statistics/JUnit paths, including a restored rerun.
const ownerHelper = path.join(project, 'src/beam_owner_support.erl');
const ownerSource = await readFile(ownerHelper, 'utf8');
for (const [name, before, after] of [
  ['borrower timeout', 'touch(Owner) ->\n    lawspec_beam_resource:call(Owner, fun() -> ets:insert(get(owner_store), {note, 1}) end).',
    'touch(_Owner) -> receive never -> true end.'],
  ['release failure', '    true = ets:delete(Table),', '    true = ets:delete(Table),\n    error(cleanup_failed),'],
]) {
  assert.equal(ownerSource.split(before).length, 2);
  await new Promise(resolve => setTimeout(resolve, 1100));
  await writeFile(ownerHelper, ownerSource.replace(before, after));
  try {
    const result = (await test(['--fresh', '--tag', 'owners', '--report', 'junit=owners.xml'],
      {pass: false, environment})).json[0];
    assert.equal(result.ok, false, name);
    assert.deepEqual(result.ran, plan.tests.filter(row => row.tags.includes('owners')).map(row => row.law));
    const reports = await harnessStatistics(statsPath);
    assert.ok(reports.some(row => row.law === 'example.resourceOwners::owners release after each test'
      && row.outcome === 'failed' && row.failureKind === 'harness' && row.attempts === 1), name);
    assert.match(await readFile(path.join(base, 'owners.xml'), 'utf8'), /<failure/);
  } finally {
    await new Promise(resolve => setTimeout(resolve, 1100));
    await writeFile(ownerHelper, ownerSource);
  }
  const restored = (await test(['--fresh', '--tag', 'owners'])).json[0];
  assert.ok(restored.ok && !restored.unrun, JSON.stringify(restored));
}
console.log('PASS dedicated resource owners, timeout/cleanup failures, exact selection, JUnit and restored reruns');
console.log(`Installed public BEAM harness integration passed: ${language} ${bits} ${minify ? 'compact' : 'readable'}`);
