// Generated from templates/tools/beam-crypto-integration.mjs by lawspec-dev generate. Do not edit.
// The installed CLI must connect crypto planning, native build hooks, the C NIF,
// native properties/vectors, coverage, caching and failure replay.
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {cp, mkdir, readFile, readdir, rm, stat, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

const exec = promisify(execFile), repo = path.resolve(import.meta.dirname, '..');
const language = process.argv[2];
assert.ok(['erlang', 'elixir', 'gleam'].includes(language), 'Pass a BEAM target');
const bits = Number(process.env.LAWSPEC_MACHINE_BITS ?? 64);
assert.ok([32, 64].includes(bits));
const minify = process.env.LAWSPEC_MINIFY === '1';
const base = path.join(repo, '.artifacts/beam-crypto-integration', `${language}-${bits}-${minify}`);
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
    timeout: 300000, maxBuffer: 32 * 1024 * 1024}); }
  catch (error) { result = error; }
  const output = (result.stdout ?? '') + (result.stderr ?? '');
  await writeFile(path.join(base, `${String(++step).padStart(2, '0')}-${path.basename(command)}.log`), output);
  assert.ok(!result.killed && !result.signal, `Native process did not finish: ${output}`);
  if (pass) assert.equal(result.code ?? 0, 0, output);
  else assert.ok(Number.isInteger(result.code) && result.code > 0, `Expected failed command: ${output}`);
  return {stdout: result.stdout ?? '', stderr: result.stderr ?? '', output};
}
const packageSource = process.env.LAWSPEC_NPM_SOURCE;
const packed = JSON.parse((await run('npm', ['pack', '--json', '--pack-destination', base,
  ...(packageSource ? ['--ignore-scripts'] : [])], path.resolve(packageSource ?? path.join(repo, 'npm')))).stdout)[0];
const installation = path.join(base, 'installation');
await run('npm', ['install', '--offline', '--ignore-scripts', '--no-audit', '--no-fund',
  '--prefix', installation, path.join(base, packed.filename)], base);
const packageRoot = path.join(installation, 'node_modules/lawspec');
const cli = path.join(packageRoot, 'bin/lawspec.mjs');
const configFile = path.join(base, 'lawspec.json');
async function call(verb, flags = [], options = {}) {
  const result = await run(process.execPath, [cli, verb, '--config', configFile, ...flags], base, options);
  return {...result, ...(flags.includes('--json') ? {json: JSON.parse(result.stdout)} : {})};
}
const layoutFlags = minify ? ['--minify'] : [];
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

const source = await readFile(path.join(repo, 'examples/specs/crypto.lawspec'), 'utf8');
await writeFile(path.join(base, 'crypto.lawspec'), source);
const config = JSON.parse(await readFile(configFile, 'utf8'));
config.sources = ['crypto.lawspec'];
config.targets[0].nativeBindings = JSON.parse(await readFile(path.join(repo, 'acceptance/crypto', language, 'bindings.json'), 'utf8'));
await writeFile(configFile, JSON.stringify(config, null, 2) + '\n');
for (const kind of ['files', 'native'])
  await cp(path.join(repo, 'acceptance/crypto', language, kind), project, {recursive: true});

// These are the documented changes an existing application makes for crypto.
// Doctor must reject missing hooks before any generated files are written.
if (language !== 'gleam') {
  const absent = await call('generate', ['--json', ...layoutFlags], {pass: false});
  assert.match(absent.output, language === 'erlang' ? /compile pre_hook/ : /Add :lawspec_crypto/);
}
if (language === 'erlang') {
  const file = path.join(project, 'rebar.config');
  await writeFile(file, (await readFile(file, 'utf8')) +
    '{pre_hooks, [{compile, "escript lawspec_crypto_build.escript"}]}.\n');
  const app = path.join(project, 'src/lawspec_example.app.src');
  await writeFile(app, (await readFile(app, 'utf8')).replace('[kernel, stdlib]', '[kernel, stdlib, crypto]'));
}
if (language === 'elixir') {
  const file = path.join(project, 'mix.exs');
  const original = await readFile(file, 'utf8');
  assert.equal(original.split('deps: [').length, 2);
  await writeFile(file, `defmodule Mix.Tasks.Compile.LawspecCrypto do
  use Mix.Task.Compiler
  def run(_args) do
    {output, status} = System.cmd("escript", ["lawspec_crypto_build.escript"], stderr_to_stdout: true)
    IO.write(output)
    if status != 0, do: Mix.raise("LawSpec crypto bridge compilation failed")
    {:ok, []}
  end
end

` + original.replace('deps: [', 'compilers: [:lawspec_crypto] ++ Mix.compilers(),\n     deps: [')
    .replace('[:logger]', '[:logger, :crypto]'));
}
const badCompiler = await call('generate', ['--json', ...layoutFlags],
  {pass: false, environment: {CC: 'lawspec-missing-c-compiler'}});
assert.match(badCompiler.output, /executable not found/);
await assert.rejects(stat(path.join(project, 'priv/lawspec_crypto_native.c')), {code: 'ENOENT'});
await call('check', ['--json']);
await call('generate', ['--json', ...layoutFlags]);
await call('generate', ['--check', ...layoutFlags]);
assert.ok((await stat(path.join(project, 'priv/lawspec_crypto_native.c'))).size > 0);
await assert.rejects(stat(path.join(project, 'priv/lawspec_crypto_native.so')), {code: 'ENOENT'});
console.log('PASS generation checks build hooks and real C toolchain without writing failed plans');

const {createCompiler} = await import(pathToFileURL(path.join(packageRoot, 'api.mjs')));
const compiler = await createCompiler();
const plan = await compiler.planGeneration({target: language, machineBits: bits, minify,
  sources: [{path: 'crypto.lawspec', content: source}], nativeBindings: config.targets[0].nativeBindings});
assert.deepEqual(plan.diagnostics, []);
assert.equal(plan.tests.length, 19, 'Run all imported crypto laws plus application laws');
const first = (await call('test', ['--fresh', '--seed', '4201', '--coverage', '--report', 'junit=crypto.xml', '--json', ...layoutFlags])).json[0];
assert.equal(first.ok, true, JSON.stringify(first));
assert.deepEqual(first.ran, plan.tests.map(test => test.law));
const library = path.join(project, 'priv/lawspec_crypto_native.so');
assert.ok((await stat(library)).size > 1000, 'The native runner must build a real NIF');
const built = await stat(library);
const coverage = JSON.parse(await readFile(path.resolve(base, first.coverage, 'coverage.json'), 'utf8'));
assert.ok(coverage.summary.covered > 0);
assert.match(await readFile(path.join(base, 'crypto.xml'), 'utf8'), /testsuite/);
const cached = (await call('test', ['--json', ...layoutFlags])).json[0];
assert.ok(cached.ok && cached.ran.length === 0 && cached.unchanged === plan.tests.length, JSON.stringify(cached));
assert.equal((await stat(library)).mtimeMs, built.mtimeMs, 'Unchanged code must reuse the compiled NIF');
console.log('PASS installed crypto laws, coverage, JUnit, native C build and cached results');

// A fresh run must repair a damaged build artifact before loading the library.
await writeFile(library, 'damaged build output');
const repaired = (await call('test', ['--fresh', '--seed', '4201', '--json', ...layoutFlags])).json[0];
assert.ok(repaired.ok && repaired.ran.length === plan.tests.length, JSON.stringify(repaired));
assert.ok((await stat(library)).size > 1000);

// The ordinary native runner also executes the standalone NIST vector suites.
const nativeCommand = {erlang: ['rebar3', ['eunit']], elixir: ['mix', ['test']], gleam: ['gleam', ['test']]}[language];
const native = (await run(...nativeCommand)).output.replace(/\x1b\[[0-9;]*m/g, '');
assert.match(native, {erlang: /All 62 tests passed/, elixir: /Result: 62 passed/, gleam: /62 passed, no failures/}[language],
  'All generated crypto checks and the twelve vector checks must run');
console.log('PASS repaired NIF and ordinary native crypto/vector suites');

for (const mutant of (await readdir(path.join(repo, 'acceptance/crypto', language, 'mutants'))).filter(file => file.endsWith('.mutant')).sort()) {
  const mutation = await readFile(path.join(repo, 'acceptance/crypto', language, 'mutants', mutant), 'utf8');
  const match = /^expect: (.+)\n@@ (.+)\n<<<<<<<\n([\s\S]*?)\n=======\n([\s\S]*?)\n>>>>>>>\s*$/.exec(mutation);
  assert.ok(match, `Unrecognized crypto mutant: ${mutant}`);
  const [, expected, file, before, after] = match;
  const destination = path.join(project, file), original = await readFile(destination, 'utf8');
  assert.equal(original.split(before).length, 2);
  await new Promise(resolve => setTimeout(resolve, 1100));
  await writeFile(destination, original.replace(before, after));
  try {
    const failed = await call('test', ['--seed', '811', '--json', ...layoutFlags], {pass: false});
    assert.equal(failed.json[0].ok, false);
    assert.ok(failed.json[0].ran.some(law => law.includes(expected)), `Missing failed law: ${expected}`);
    assert.ok(failed.output.includes(expected), `The native failure must identify ${expected}`);
    assert.match(failed.stderr, /property_failed|equation_failed|PropertyFailed|EquationFailed/,
      'A crypto mutant must reach a native assertion, not fail compilation or setup');
  } finally {
    await new Promise(resolve => setTimeout(resolve, 1100));
    await writeFile(destination, original);
  }
  const recovery = (await call('test', ['--json', ...layoutFlags])).json[0];
  assert.ok(recovery.ok && recovery.ran.some(law => law.includes(expected)), JSON.stringify(recovery));
  console.log(`PASS ${mutant}: genuine native failure and automatic replay after repair`);
}
await call('generate', ['--check', ...layoutFlags]);
console.log(`Installed ${language} crypto: all laws, C build, vectors, coverage, caching, mutants and replay pass (${bits}, compact=${minify})`);
