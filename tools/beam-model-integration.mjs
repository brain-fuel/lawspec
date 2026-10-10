// Generated from templates/tools/beam-model-integration.mjs by lawspec-dev generate. Do not edit.
// Installed BEAM model evidence must participate in exact native selection,
// cache invalidation, JUnit reporting and failed-seed replay.
// ref:REQ-test-manifest ref:DEC-stateful-models-linearizability
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
const base = path.join(repo, '.artifacts/beam-model-integration', `${language}-${bits}-${minify}`);
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
const sources = await Promise.all(['examples/specs/models.lawspec', 'examples/specs/actors.lawspec']
  .map(async file => ({path: path.basename(file), content: await readFile(path.join(repo, file), 'utf8')})));
sources.sort((a, b) => a.path.localeCompare(b.path));
for (const source of sources) await writeFile(path.join(base, source.path), source.content);
const config = JSON.parse(await readFile(configFile, 'utf8'));
config.sources = sources.map(source => source.path);
await writeFile(configFile, JSON.stringify(config, null, 2) + '\n');
await call('generate', ['--json', ...layoutFlags]);
for (const suite of ['models', 'actors'])
  for (const kind of ['files', 'native'])
    await cp(path.join(repo, 'acceptance', suite, language, kind), project, {recursive: true});
await call('generate', ['--check', ...layoutFlags]);

const {createCompiler} = await import(pathToFileURL(path.join(packageRoot, 'api.mjs')));
const {invocations, executedTests} = await import(pathToFileURL(path.join(packageRoot, 'test-command.mjs')));
const {projectKey} = await import(pathToFileURL(path.join(packageRoot, 'failure-database.mjs')));
const compiler = await createCompiler();
const plan = await compiler.planGeneration({target: language, machineBits: bits, minify, sources});
assert.deepEqual(plan.diagnostics, []);
assert.equal(plan.tests.length, 18, 'Six ordinary laws, eleven model/scenario checks and one supervision check');
const models = plan.tests.filter(test => test.law.includes('::model::'));
assert.equal(models.length, 11);
const identity = entry => `${entry.unit}::${entry.name}`;
const first = (await call('test', ['--fresh', '--seed', '4201', '--report', 'junit=models.xml', '--json', ...layoutFlags])).json[0];
assert.ok(first.ok && !first.unrun, JSON.stringify(first));
assert.deepEqual(first.ran, plan.tests.map(test => test.law));
const junit = await readFile(path.join(base, 'models.xml'), 'utf8');
for (const check of [...models, plan.tests.find(test => test.name === 'supervision')])
  assert.ok(junit.includes(language === 'erlang' ? check.label : check.name), `Missing native JUnit case ${check.name}`);
const cached = (await call('test', ['--json', ...layoutFlags])).json[0];
assert.ok(cached.ok && cached.ran.length === 0 && cached.unchanged === plan.tests.length, JSON.stringify(cached));

const selected = [plan.tests[0],
  plan.tests.find(test => test.unit === 'example.models' && test.name === 'model_counter__parallel'),
  plan.tests.find(test => test.name === 'model_counter__scenario_a_reply_is_delegated'),
  plan.tests.find(test => test.name === 'supervision')];
assert.ok(selected.every(Boolean));
const [invocation] = invocations({language}, selected, {scratch: base, root: project, offline: env.LAWSPEC_OFFLINE === '1'});
const subset = await run(invocation.command, invocation.args, project, {environment: invocation.env});
const completions = await executedTests(invocation.report, subset.output, project, Date.now());
assert.deepEqual([...new Set(completions.map(test => test.identity))].sort(), selected.map(identity).sort());
assert.ok(completions.every(test => test.status === 'passed'));
for (const entry of selected.slice(1))
  assert.equal(completions.filter(test => test.identity === identity(entry)).length, 1, 'Each model check executes once');
console.log('PASS complete manifest, native JUnit, unchanged cache and exact mixed selection');

// Ordinary discovery must find the same checks once, without a second model facade.
const report = {kind: 'beam-events', file: path.join(base, 'native.jsonl'), run: 'native-model-discovery'};
const [command, args] = {erlang: ['rebar3', ['eunit']], elixir: ['mix', ['test']], gleam: ['gleam', ['test']]}[language];
const native = await run(command, args, project, {environment: {LAWSPEC_BEAM_REPORT: report.file, LAWSPEC_BEAM_RUN: report.run}});
const nativeRows = await executedTests(report, native.output, project, Date.now());
assert.deepEqual([...new Set(nativeRows.map(test => test.identity))].sort(), plan.tests.map(identity).sort());
assert.ok(nativeRows.every(test => test.status === 'passed'));
for (const entry of models)
  assert.equal(nativeRows.filter(test => test.identity === identity(entry)).length, 1, 'No duplicated model tests');

const mutation = await readFile(path.join(repo, 'acceptance/models', language, 'mutants/pop.mutant'), 'utf8');
const match = /^expect-any: .+\n@@ (.+)\n<<<<<<<\n([\s\S]*?)\n=======\n([\s\S]*?)\n>>>>>>>\s*$/.exec(mutation);
assert.ok(match);
const [, file, before, after] = match, destination = path.join(project, file);
const original = await readFile(destination, 'utf8');
assert.equal(original.split(before).length, 2);
const stack = models.find(test => test.name === 'model_stack__sequential');
const databaseFile = path.join(base, '.lawspec/failures', language, projectKey(project), 'laws.json');
await new Promise(resolve => setTimeout(resolve, 1100));
await writeFile(destination, original.replace(before, after));
try {
  const failed = await call('test', ['--seed', '811', '--json', ...layoutFlags], {pass: false});
  assert.equal(failed.json[0].ok, false);
  assert.match(failed.output, /model_failed|ModelFailed/);
  assert.ok(failed.json[0].ran.includes(stack.law));
  assert.equal(JSON.parse(await readFile(databaseFile, 'utf8'))[stack.law]?.seed, 811);
  const replay = await call('test', ['--json', ...layoutFlags], {pass: false});
  assert.equal(replay.json[0].ok, false);
  assert.match(replay.output, /model_failed|ModelFailed/);
  assert.ok(replay.json[0].ran.includes(stack.law));
  assert.equal(JSON.parse(await readFile(databaseFile, 'utf8'))[stack.law]?.seed, 811, 'Replay preserves the failing model seed');
} finally {
  await new Promise(resolve => setTimeout(resolve, 1100));
  await writeFile(destination, original);
}
const repaired = (await call('test', ['--json', ...layoutFlags])).json[0];
assert.ok(repaired.ok && repaired.ran.includes(stack.law), JSON.stringify(repaired));
assert.equal(JSON.parse(await readFile(databaseFile, 'utf8'))[stack.law], undefined);
await call('generate', ['--check', ...layoutFlags]);
console.log(`Installed ${language} models: selection, discovery, cache, JUnit, mutation and seed replay passed (${bits}, compact=${minify})`);
