// Generated from templates/tools/multi-project-replay.mjs by lawspec-dev generate. Do not edit.
// Projects sharing a language must retain independent failing seeds and inputs.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {cp, mkdir, readFile, readdir, rm, symlink, writeFile} from 'node:fs/promises';
import path from 'node:path';

const exec = promisify(execFile), repo = path.resolve(import.meta.dirname, '..');
const language = process.argv[2] ?? 'javascript';
assert.ok(['javascript', 'erlang', 'elixir', 'gleam'].includes(language));
const bits = Number(process.env.LAWSPEC_MACHINE_BITS ?? 64), minify = process.env.LAWSPEC_MINIFY === '1';
assert.ok([32, 64].includes(bits));
const maxFailures = process.env.LAWSPEC_EXUNIT_MAX_FAILURES ?? 'infinity';
assert.ok(maxFailures === 'infinity' || /^[1-9][0-9]*$/.test(maxFailures));
const base = path.join(repo, '.artifacts/multi-project-replay', `${language}-${bits}-${minify}`);
await rm(base, {recursive: true, force: true});
await mkdir(base, {recursive: true});
const env = {...process.env, npm_config_cache: path.join(repo, '.artifacts/npm-cache')};
if (env.LAWSPEC_OFFLINE === '1') env.HEX_OFFLINE = '1';
let step = 0;
async function run(command, args, cwd = base, pass = true) {
  let result;
  try { result = await exec(command, args, {cwd, env, timeout: 120000, maxBuffer: 8 * 1024 * 1024}); }
  catch (error) { result = error; }
  const output = (result.stdout ?? '') + (result.stderr ?? '');
  await writeFile(path.join(base, `${++step}-${path.basename(command)}.log`), output);
  assert.ok(!result.killed && !result.signal, `Native process did not finish: ${output}`);
  if (pass) assert.equal(result.code ?? 0, 0, output);
  else assert.ok(Number.isInteger(result.code) && result.code > 0, output);
  return {stdout: result.stdout ?? '', output};
}
const source = process.env.LAWSPEC_NPM_SOURCE;
const packed = JSON.parse((await run('npm', ['pack', '--json', '--pack-destination', base,
  ...(source ? ['--ignore-scripts'] : [])], path.resolve(source ?? path.join(repo, 'npm')))).stdout)[0];
const installation = path.join(base, 'installation');
await run('npm', ['install', '--offline', '--ignore-scripts', '--no-audit', '--no-fund',
  '--prefix', installation, path.join(base, packed.filename)]);
const cli = path.join(installation, 'node_modules/lawspec/bin/lawspec.mjs');
const call = (verb, flags = [], pass = true) => run(process.execPath, [cli, verb, ...flags,
  ...(['generate', 'test'].includes(verb) && minify ? ['--minify'] : [])], base, pass);
const projects = ['first project', 'second project'].map(name => path.join(base, name));
for (const project of projects) {
  await call('init', ['--target', language, '--project', project, '--machine-bits', String(bits), ...(minify ? ['--minify'] : [])]);
  if (language === 'javascript') {
    if (env.LAWSPEC_NODE_MODULES)
      await symlink(path.resolve(env.LAWSPEC_NODE_MODULES), path.join(project, 'node_modules'));
    else await run('npm', ['install', '--ignore-scripts', '--no-audit', '--no-fund',
      ...(env.LAWSPEC_OFFLINE === '1' ? ['--offline'] : [])], project);
  } else {
    const lock = {erlang: 'rebar.lock', elixir: 'mix.lock', gleam: 'manifest.toml'}[language];
    await cp(path.join(repo, 'test/locks', language, lock), path.join(project, lock));
    const dependencies = env.LAWSPEC_BEAM_DEPENDENCIES;
    if (dependencies) {
      const folders = language === 'erlang' ? ['_build/test/lib/proper'] :
        language === 'elixir' ? ['deps/stream_data', '_build/test/lib/stream_data'] : ['build/packages'];
      for (const folder of folders) {
        await mkdir(path.dirname(path.join(project, folder)), {recursive: true});
        await cp(path.join(dependencies, folder), path.join(project, folder), {recursive: true});
      }
    }
    if (language === 'erlang') await run('rebar3', ['as', 'test', 'compile'], project);
    if (language === 'elixir') {
      env.MIX_ENV = 'test';
      const helper = path.join(project, 'test/test_helper.exs');
      await writeFile(helper, await readFile(helper, 'utf8') +
        `\nExUnit.configure(max_failures: ${maxFailures === 'infinity' ? ':infinity' : maxFailures})\n`);
      if (!dependencies) await run('mix', ['deps.get'], project);
      await run('mix', ['deps.compile'], project);
    }
    if (language === 'gleam') await run('gleam', ['build'], project);
  }
}
const configFile = path.join(base, 'lawspec.json');
const config = JSON.parse(await readFile(configFile, 'utf8'));
config.sources = ['replay.lawspec'];
await writeFile(configFile, JSON.stringify(config, null, 2));
await writeFile(path.join(base, 'replay.lawspec'),
  'unit example.replay\nobserve :: Int32 -> Int32\n' +
  'law `values survive` is definition is `for all` (value :: Int32 where value >= 100 && value <= 200) . observe value = value end end\n');
await call('generate');
const [adapterFile, adapter, mutant] = {
  javascript: ['src/example/replay.mjs', 'export function observe(value) { return value; }\n',
    'export function observe(value) { return value >= 111 && value <= 190 ? value + 1 : value; }\n'],
  erlang: ['src/example_replay.erl', '-module(example_replay).\n-export([observe/1]).\nobserve(Value) -> Value.\n',
    '-module(example_replay).\n-export([observe/1]).\nobserve(Value) when Value >= 111, Value =< 190 -> Value + 1;\nobserve(Value) -> Value.\n'],
  elixir: ['lib/example_replay.ex', 'defmodule Example.Replay do\n  def observe(value), do: value\nend\n',
    'defmodule Example.Replay do\n  def observe(value) when value >= 111 and value <= 190, do: value + 1\n  def observe(value), do: value\nend\n'],
  gleam: ['src/example/replay.gleam', 'pub fn observe(value: Int) -> Int { value }\n',
    'pub fn observe(value: Int) -> Int { case value >= 111 && value <= 190 { True -> value + 1 False -> value } }\n'],
}[language];
const adapters = projects.map(project => path.join(project, adapterFile));
for (const file of adapters) await writeFile(file, adapter);
const first = JSON.parse((await call('test', ['--json', '--report', 'junit=first.xml'])).stdout);
assert.ok(first.every(result => result.ok && result.ran.length === 1), JSON.stringify(first));
assert.deepEqual(first.map(result => result.root), ['first project', 'second project']);
const junit = await readFile(path.join(base, 'first.xml'), 'utf8');
for (const project of config.targets)
  assert.ok(junit.includes(`${language} (${project.root}):`), 'JUnit must distinguish projects using the same language');
assert.ok(JSON.parse((await call('test', ['--json'])).stdout).every(result => result.ran.length === 0));
const law = first[0].ran[0];
await new Promise(resolve => setTimeout(resolve, 1100));
await writeFile(adapters[0], mutant);
const failure = await call('test', ['--seed', '7340271', '--json'], false);
const failed = JSON.parse(failure.stdout);
if (language === 'elixir' && maxFailures === '1')
  assert.match(failure.output, /--max-failures reached/, 'The installed CLI must reach native fail-fast');
assert.equal(failed[0].ok, false);
assert.equal(failed[1].ok, true);
const legacy = path.join(base, '.lawspec/failures', language);
const directories = projects.map(project => path.join(legacy,
  createHash('sha256').update(project).digest('hex').slice(0, 12)));
async function database(directory) {
  try { return JSON.parse(await readFile(path.join(directory, 'laws.json'), 'utf8')); }
  catch (error) {
    if (error.code !== 'ENOENT') throw error;
    return JSON.parse(await readFile(path.join(legacy, 'laws.json'), 'utf8'));
  }
}
const retained = await database(directories[0]);
assert.equal(retained[law]?.seed, 7340271, 'A passing second project must not clear the first project\'s failure');
assert.deepEqual(await database(directories[1]), {}, 'The second project must have its own passing state');
const inputs = await readdir(path.join(directories[0], 'inputs'));
assert.ok(inputs.length > 0, 'The first project must retain its actual failing inputs');
const input = JSON.parse(await readFile(path.join(directories[0], 'inputs', inputs[0]), 'utf8'));
assert.equal(input.law, 'example.replay::values survive');
if (language === 'javascript') {
  // Its refined generator shrinks over its own tree. Retain exactly the
  // counterexample that it reports, even when that tree stops above 111.
  const reported = Number(failure.output.match(/refined counterexample=(\d+)/)?.[1]);
  assert.ok(Number.isInteger(reported) && reported >= 111 && reported <= 190);
  assert.deepEqual(input.inputs, [Buffer.from([((2 * reported) & 127) | 128, (2 * reported) >> 7]).toString('hex')]);
} else assert.deepEqual(input.inputs, ['de01'], 'Native shrinking must retain the smallest failing input, 111');
assert.equal(failed[1].ran.length, 0, 'Another project\'s failure must not invalidate a cached pass');
console.log('PASS two same-language projects retain separate reports, cached results, failure seeds and inputs');

await new Promise(resolve => setTimeout(resolve, 1100));
await writeFile(adapters[0], adapter);
const recovered = await call('test', ['--json']);
const summaries = JSON.parse(recovered.stdout);
assert.ok(summaries[0].ok && summaries[0].ran.includes(law));
assert.ok(summaries[1].ok && summaries[1].ran.length === 0);
assert.match(recovered.output, /replaying the failing inputs kept in \.lawspec\/failures/);
assert.deepEqual(await database(directories[0]), {});
assert.deepEqual(await readdir(path.join(directories[0], 'inputs')), []);
console.log('PASS repair replays only the failed project and clears its own counterexample');

// Project identity remains stable when another target is removed and re-added.
await writeFile(configFile, JSON.stringify({...config, targets: config.targets.slice(0, 1)}, null, 2));
assert.deepEqual(JSON.parse((await call('test', ['--json'])).stdout)[0].ran, []);
await writeFile(configFile, JSON.stringify(config, null, 2));
assert.ok(JSON.parse((await call('test', ['--json'])).stdout).every(result => result.ran.length === 0));
console.log(`PASS project state survives removing and re-adding another target (${language}, ${bits}, compact=${minify}, max_failures=${maxFailures})`);

if (language === 'elixir' && ['1', '2'].includes(maxFailures)) {
  const spec = path.join(base, 'replay.lawspec');
  await writeFile(spec, await readFile(spec, 'utf8') +
    ['a second law', 'a third law'].map(name =>
      `law \`${name}\` is definition is \`for all\` (value :: Int32 where value >= 100 && value <= 200) . observe value = value end end\n`).join(''));
  await call('generate');
  const complete = JSON.parse((await call('test', ['--json'])).stdout);
  assert.ok(complete.every(result => result.ok && result.ran.length === 3));
  const selected = complete[0].ran;
  await new Promise(resolve => setTimeout(resolve, 1100));
  await writeFile(adapters[0], 'defmodule Example.Replay do\n  def observe(value), do: value + 1\nend\n');
  const stopped = await call('test', ['--seed', '7340271', '--json', '--report', 'junit=limit.xml'], false);
  assert.match(stopped.output, /--max-failures reached/);
  const stoppedSummary = JSON.parse(stopped.stdout);
  assert.equal(stoppedSummary[0].ok, false);
  assert.deepEqual(stoppedSummary[0].ran, selected);
  assert.ok(stoppedSummary[1].ok && stoppedSummary[1].ran.length === 0);
  const limitedReport = await readFile(path.join(base, 'limit.xml'), 'utf8');
  assert.equal([...limitedReport.matchAll(/<testcase\b/g)].length, Number(maxFailures),
    'The native report must contain only the cases ExUnit actually completed');
  const resultFile = path.join(base, '.lawspec/results', `${language}-${path.basename(directories[0])}.json`);
  assert.deepEqual(JSON.parse(await readFile(resultFile, 'utf8')).laws, {},
    'An interrupted native batch must invalidate every selected cached law');
  assert.deepEqual(Object.keys(await database(directories[0])).sort(), [...selected].sort());
  await new Promise(resolve => setTimeout(resolve, 1100));
  await writeFile(adapters[0], adapter);
  const resumed = JSON.parse((await call('test', ['--json'])).stdout);
  assert.ok(resumed[0].ok);
  assert.deepEqual(resumed[0].ran, selected);
  assert.ok(resumed[1].ok && resumed[1].ran.length === 0);
  assert.deepEqual(await database(directories[0]), {});
  assert.ok(JSON.parse((await call('test', ['--json'])).stdout).every(result => result.ran.length === 0));
  console.log(`PASS native max_failures=${maxFailures} reports only completed cases and replays every interrupted law before caching`);
}
