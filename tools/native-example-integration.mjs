// Generated from templates/tools/native-example-integration.mjs by lawspec-dev generate. Do not edit.
// Exercise the installed public CLI and each project's normal native build tool.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {cp, mkdir, readFile, readdir, writeFile, rm, symlink} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const target = process.argv[2];
const mutations = {
  rust: ['src/domain.rs', 'Decimal::new(2.into()', 'Decimal::new(3.into()'],
  python: ['src/payments_domain.py', 'Fraction(1, 5)', 'Fraction(3, 10)'],
  javascript: ['src/payments_domain.mjs', 'new ls.Decimal(2n, -1n)', 'new ls.Decimal(3n, -1n)'],
  typescript: ['src/payments_domain.ts', 'new ls.Decimal(2n, -1n)', 'new ls.Decimal(3n, -1n)'],
  java: ['src/main/java/domain/PaymentsDomain.java', 'BigDecimal("0.2")', 'BigDecimal("0.3")'],
  kotlin: ['src/main/kotlin/domain/PaymentsDomain.kt', 'BigDecimal("0.2")', 'BigDecimal("0.3")'],
  go: ['example/payments/domain.go', 'big.NewInt(2)', 'big.NewInt(3)'],
  haskell: ['src/PaymentsDomain.hs', 'amount + 1 % 5', 'amount + 3 % 10'],
  erlang: ['src/payments_domain.erl', 'decimal(2, -1)', 'decimal(3, -1)'],
  elixir: ['lib/payments_domain.ex', 'decimal(2, -1)', 'decimal(3, -1)'],
  gleam: ['src/payments_domain.gleam', 'decimal(2, -1)', 'decimal(3, -1)'],
};
assert.ok(Object.hasOwn(mutations, target), 'Pass one of the eleven target names');
const bits = Number(process.env.LAWSPEC_MACHINE_BITS ?? 64);
assert.ok(bits === 32 || bits === 64);
const minify = process.env.LAWSPEC_MINIFY === '1';
const offline = process.env.LAWSPEC_OFFLINE === '1';
const base = path.join(root, '.artifacts/native-example-integration', `${target}-${bits}-${minify}`);
await rm(base, {recursive: true, force: true});
await mkdir(base, {recursive: true});
const env = {...process.env, npm_config_cache: path.join(root, '.artifacts/npm-cache'),
  PYTHONDONTWRITEBYTECODE: '1', GOCACHE: path.join(root, '.artifacts/go-cache')};
if (offline) Object.assign(env, {CARGO_NET_OFFLINE: 'true', GOPROXY: 'off', GOTOOLCHAIN: 'local',
  HEX_OFFLINE: '1', MAVEN_ARGS: `${env.MAVEN_ARGS ?? ''} -o`.trim()});
let step = 0;
async function run(command, args, cwd, pass = true) {
  console.log(`${target}: ${command} ${args.join(' ')}`);
  const result = spawnSync(command, args, {cwd, env, encoding: 'utf8', timeout: 600000,
    maxBuffer: 32 * 1024 * 1024});
  const output = (result.stdout ?? '') + (result.stderr ?? '');
  await writeFile(path.join(base, `${String(++step).padStart(2, '0')}-${path.basename(command)}.log`), output);
  assert.equal(result.error, undefined, `${command}: ${result.error}\n${output}`);
  if (pass) assert.equal(result.status, 0, output);
  else assert.ok(result.status > 0, `Expected failed native tests\n${output}`);
  return pass ? result.stdout : output;
}
// A prepared development package can exercise this same installed-CLI gate
// before the repository's release WASM is rebuilt. Release CI uses npm/.
const packageSource = process.env.LAWSPEC_NPM_SOURCE;
const packed = JSON.parse(await run('npm', ['pack', '--json', '--pack-destination', base,
  ...(packageSource ? ['--ignore-scripts'] : [])], path.resolve(packageSource ?? path.join(root, 'npm'))))[0];
const installation = path.join(base, 'installation');
await run('npm', ['install', '--offline', '--ignore-scripts', '--no-audit', '--no-fund',
  '--prefix', installation, path.join(base, packed.filename)], base);
const cli = path.join(installation, 'node_modules/lawspec/bin/lawspec.mjs');
const exported = await run(process.execPath, [cli, 'examples', '--example', 'payments',
  '--target', target, '--machine-bits', String(bits), ...(minify ? ['--minify'] : []), '--json'], base);
const projects = JSON.parse(exported);
assert.equal(projects.length, 1);
const directory = projects[0].directory;
const configPath = path.join(directory, 'lawspec.json');
const config = JSON.parse(await readFile(configPath, 'utf8'));
if (target === 'python') {
  if (process.env.LAWSPEC_PYTHON_EXECUTABLE) {
    config.targets[0].python = process.env.LAWSPEC_PYTHON_EXECUTABLE;
  } else {
    await run('uv', ['venv', '--python', process.env.LAWSPEC_PYTHON || '3.13', '.venv'], directory);
    config.targets[0].python = path.join(directory, '.venv/bin/python');
    await run('uv', ['pip', 'install', '--python', config.targets[0].python,
      ...(offline ? ['--offline'] : []), '-e', '.[test]'], directory);
  }
} else if (target === 'javascript' || target === 'typescript') {
  if (process.env.LAWSPEC_NODE_MODULES) {
    await symlink(path.resolve(process.env.LAWSPEC_NODE_MODULES), path.join(directory, 'node_modules'));
  } else {
    await run('npm', ['install', '--ignore-scripts', '--no-audit', '--no-fund',
      ...(offline ? ['--offline'] : [])], directory);
  }
} else if (target === 'go') {
  await run('go', ['mod', 'download', 'pgregory.net/rapid'], directory);
} else if (target === 'haskell') {
  await run('stack', ['--no-terminal', 'build', '--test', '--only-dependencies'], directory);
} else if (target === 'kotlin' && process.env.LAWSPEC_GRADLE) {
  config.targets[0].gradle = process.env.LAWSPEC_GRADLE;
} else if (['erlang', 'elixir', 'gleam'].includes(target)) {
  const lock = {erlang: 'rebar.lock', elixir: 'mix.lock', gleam: 'manifest.toml'}[target];
  await cp(path.join(root, 'test/locks', target, lock), path.join(directory, lock));
  // Optional dependency cache for offline validation; never copy the application
  // under test or generated support modules from a previous build.
  const dependencies = process.env.LAWSPEC_BEAM_DEPENDENCIES;
  if (dependencies) {
    const folders = target === 'erlang' ? ['_build/test/lib/proper'] :
      target === 'elixir' ? ['deps/stream_data', '_build/test/lib/stream_data'] : ['build/packages'];
    for (const folder of folders) {
      await mkdir(path.dirname(path.join(directory, folder)), {recursive: true});
      await cp(path.join(dependencies, folder), path.join(directory, folder), {recursive: true});
    }
  }
  if (target === 'erlang') await run('rebar3', ['as', 'test', 'compile'], directory);
  if (target === 'elixir') {
    const previous = env.MIX_ENV;
    env.MIX_ENV = 'test';
    try {
      if (!dependencies) await run('mix', ['deps.get'], directory);
      await run('mix', ['deps.compile'], directory);
    } finally {
      if (previous === undefined) delete env.MIX_ENV;
      else env.MIX_ENV = previous;
    }
  }
  if (target === 'gleam') await run(process.execPath, ['prepare.mjs'], directory);
}
await writeFile(configPath, JSON.stringify(config, null, 2) + '\n');
await run(process.execPath, [cli, 'check'], directory);
await run(process.execPath, [cli, 'generate', ...(minify ? ['--minify'] : [])], directory);
const commands = {
  rust: ['cargo', ['test', ...(offline ? ['--offline'] : [])]],
  python: [config.targets[0].python, ['-B', '-m', 'pytest', '-q']],
  javascript: ['npm', ['test']], typescript: ['npm', ['test']],
  java: ['mvn', ['-B', ...(offline ? ['-o'] : []), 'test']],
  kotlin: [config.targets[0].gradle || 'gradle', ['--no-daemon', '--console=plain',
    ...(offline ? ['--offline'] : []), 'test', '--rerun-tasks']],
  go: ['go', ['test', './...']],
  haskell: ['stack', ['--no-terminal', 'test']],
  erlang: ['rebar3', ['eunit']],
  elixir: ['mix', ['test']],
  gleam: ['gleam', ['test']],
};
const [command, args] = commands[target];
await run(command, args, directory);
const [file, before, after] = mutations[target];
const domain = path.join(directory, file);
const original = await readFile(domain, 'utf8');
assert.equal(original.split(before).length, 2, `Mutation must match exactly once in ${file}`);
async function editDomain(content) {
  // Native BEAM incremental builds use second-resolution source timestamps.
  // Give deliberate mutation/restoration separate timestamps.
  if (['erlang', 'elixir', 'gleam'].includes(target))
    await new Promise(resolve => setTimeout(resolve, 1100));
  await writeFile(domain, content);
}
try {
  await editDomain(original.replace(before, after));
  const failed = await run(command, args, directory, false);
  assert.match(failed, /fees[ _]preserve[ _]currency|decimal[ _]tenths/i,
    'The mutant must fail a generated fee test, not merely compilation');
  const shrink = {
    erlang: /Shrinking[\s\S]*\{ls_decimal,\s*100,\s*-2\}/,
    elixir: /shrunk_failure:[\s\S]*\{:ls_decimal,\s*100,\s*-2\}/,
    gleam: /Counterexample\([\s\S]*LsDecimal\(100,\s*-2\)/,
  }[target];
  if (shrink) assert.match(failed, shrink, 'The native generator must shrink the failing price to 1.00');
} finally {
  await editDomain(original);
}
// lawspec test runs each law once, then only the laws an edit can affect. A
// law that calls no adapter does not depend on the adapter's code.
const specification = path.join(directory, 'laws/payments.lawspec');
await writeFile(specification, (await readFile(specification, 'utf8')) +
  '\nlaw `integers equal themselves` is definition is `for all` (x :: Int8) . x = x end end\n');
await run(process.execPath, [cli, 'generate', ...(minify ? ['--minify'] : [])], directory);
const lawspecTest = async (flags = [], pass = true) => {
  const printed = await run(process.execPath, [cli, 'test', '--json', ...(minify ? ['--minify'] : []), ...flags], directory, pass);
  return pass ? JSON.parse(printed)[0] : printed;
};
const first = await lawspecTest();
assert.ok(first.ok && first.ran.length > 0 && first.unchanged === 0, JSON.stringify(first));
assert.deepEqual((await lawspecTest()).ran, [], 'An unchanged project runs no tests');
const comment = {python: '#', haskell: '--', erlang: '%', elixir: '#'}[target] ?? '//';
await editDomain(original + `\n${comment} edited\n`);
const edited = await lawspecTest();
assert.deepEqual(edited.ran, first.ran.filter((law) => !law.endsWith('::integers equal themselves')),
  `An adapter edit reruns the laws that call adapters, and only those: ${JSON.stringify(edited)}`);
await editDomain(original);
await lawspecTest();
try {
  await editDomain(original.replace(before, after));
  const failed = await lawspecTest(['--seed', '7340271'], false);
  assert.match(failed, /fees[ _]preserve[ _]currency|decimal[ _]tenths/i, 'lawspec test reports the failing law');
  if (['javascript', 'typescript', 'go', 'kotlin', 'haskell'].includes(target))
    assert.match(failed, /7340271/, 'The seed reaches the property tests');
  // A failing law cannot be cached as passing, so it runs again.
  assert.match(await lawspecTest([], false), /fees[ _]preserve[ _]currency|decimal[ _]tenths/i);
} finally {
  await editDomain(original);
}
// Even when reverting restores an older passing key, a recent failure must be
// replayed. Only a newly completed pass can clear that failure.
const repaired = await lawspecTest();
assert.ok(repaired.ok && repaired.ran.some(law => law.endsWith('::fees preserve currency and exact decimal value')),
  `A repaired adapter replays the failed fee law: ${JSON.stringify(repaired)}`);
assert.deepEqual((await lawspecTest()).ran, [], 'A successful replay can be cached');
const manifest = await readFile(path.join(directory, '.lawspec/generated.json'), 'utf8');
await run(process.execPath, [cli, 'examples', '--example', 'payments', '--target', target,
  '--machine-bits', String(bits), ...(minify ? ['--minify'] : [])], base);
assert.equal(await readFile(path.join(directory, '.lawspec/generated.json'), 'utf8'), manifest);
await run(process.execPath, [cli, 'generate', '--check', ...(minify ? ['--minify'] : [])], directory);

if (['erlang', 'elixir', 'gleam'].includes(target)) {
  // Adopt and remove bindings through the installed CLI. The application owns
  // its native domain, generators and build setup throughout both transitions.
  const originalConfig = await readFile(configPath, 'utf8');
  const owned = new Map();
  async function keep(relative) { owned.set(relative, await readFile(path.join(directory, relative), 'utf8')); }
  async function applicationFiles(relative = '') {
    const source = path.join(root, 'examples/native-payments', target, relative);
    for (const entry of await readdir(source, {withFileTypes: true})) {
      const file = path.join(relative, entry.name);
      if (entry.isDirectory()) await applicationFiles(file);
      else if (file !== 'lawspec.json') await keep(file);
    }
  }
  await applicationFiles();
  for (const file of {erlang: ['rebar.config'], elixir: ['mix.exs', 'test/test_helper.exs'],
    gleam: ['gleam.toml', 'test-support/gleam.toml']}[target]) await keep(file);
  async function preserved() {
    for (const [file, content] of owned)
      assert.equal(await readFile(path.join(directory, file), 'utf8'), content, `Application file changed: ${file}`);
  }
  const generate = async (pass = true) => run(process.execPath,
    [cli, 'generate', ...(minify ? ['--minify'] : [])], directory, pass);
  const bridge = path.join(directory, 'src/lawspec_native_bindings.erl');
  const bridgeContent = await readFile(bridge, 'utf8');
  const unbound = JSON.parse(originalConfig);
  delete unbound.targets[0].nativeBindings;
  await writeFile(configPath, JSON.stringify(unbound, null, 2) + '\n');
  await writeFile(bridge, bridgeContent + '\n% application edited the generated bridge\n');
  assert.match(await generate(false), /Refusing to remove edited generated file/);
  assert.equal(await readFile(path.join(directory, '.lawspec/generated.json'), 'utf8'), manifest);
  await preserved();
  await writeFile(bridge, bridgeContent);
  await generate();
  await assert.rejects(readFile(bridge), {code: 'ENOENT'});
  await preserved();
  await run(process.execPath, [cli, 'generate', '--check', ...(minify ? ['--minify'] : [])], directory);
  const removedManifest = await readFile(path.join(directory, '.lawspec/generated.json'), 'utf8');
  await writeFile(configPath, originalConfig);
  await writeFile(bridge, '% application-owned file at the future bridge path\n');
  assert.match(await generate(false), /Refusing to overwrite unowned or edited/);
  assert.equal(await readFile(path.join(directory, '.lawspec/generated.json'), 'utf8'), removedManifest);
  await preserved();
  await rm(bridge);
  await generate();
  await preserved();
  await run(command, args, directory);
  assert.ok((await lawspecTest(['--fresh'])).ok);
  await run(process.execPath, [cli, 'generate', '--check', ...(minify ? ['--minify'] : [])], directory);
  console.log(`Installed ${target}: binding removal/adoption protects edited and unowned bridges, preserves application files, and restores passing native tests`);
}
console.log(`Installed ${target}: native tests pass, wrong fee fails, lawspec test reruns only affected laws, regeneration preserves files (${bits}, compact=${minify})`);
