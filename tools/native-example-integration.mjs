// Exercise the installed public CLI and each project's normal native build tool.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile, rm, symlink} from 'node:fs/promises';
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
};
assert.ok(Object.hasOwn(mutations, target), 'Pass one of the eight target names');
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
  MAVEN_ARGS: `${env.MAVEN_ARGS ?? ''} -o`.trim()});
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
const packed = JSON.parse(await run('npm', ['pack', '--json', '--pack-destination', base], path.join(root, 'npm')))[0];
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
};
const [command, args] = commands[target];
await run(command, args, directory);
const [file, before, after] = mutations[target];
const domain = path.join(directory, file);
const original = await readFile(domain, 'utf8');
assert.equal(original.split(before).length, 2, `Mutation must match exactly once in ${file}`);
try {
  await writeFile(domain, original.replace(before, after));
  const failed = await run(command, args, directory, false);
  assert.match(failed, /fees[ _]preserve[ _]currency|decimal[ _]tenths/i,
    'The mutant must fail a generated fee test, not merely compilation');
} finally {
  await writeFile(domain, original);
}
const manifest = await readFile(path.join(directory, '.lawspec/generated.json'), 'utf8');
await run(process.execPath, [cli, 'examples', '--example', 'payments', '--target', target,
  '--machine-bits', String(bits), ...(minify ? ['--minify'] : [])], base);
assert.equal(await readFile(path.join(directory, '.lawspec/generated.json'), 'utf8'), manifest);
await run(process.execPath, [cli, 'generate', '--check', ...(minify ? ['--minify'] : [])], directory);
console.log(`Installed ${target}: native tests pass, wrong fee fails, regeneration preserves files (${bits}, compact=${minify})`);
