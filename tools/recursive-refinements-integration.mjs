// Public source-to-native execution on every supported backend, using cached tools.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, readdir, symlink, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {templates} from '../npm/templates.mjs';

const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
assert.ok(compiler, 'Set LAWSPEC_CORE');
const targets = process.argv.slice(2).length ? process.argv.slice(2) :
  ['python', 'javascript', 'typescript', 'go', 'rust', 'java', 'kotlin', 'haskell'];
const sourcePath = 'examples/specs/recursive_refinements.lawspec';
const source = await readFile(path.join(root, sourcePath), 'utf8');
const base = path.join(root, '.artifacts/recursive-refinements');
async function files(directory) {
  return (await Promise.all((await readdir(directory, {withFileTypes: true})).map(entry => {
    const file = path.join(directory, entry.name);
    return entry.isDirectory() ? files(file) : [file];
  }))).flat();
}
let kotlinDependencies;
async function kotlinClasspath() {
  if (kotlinDependencies) return kotlinDependencies;
  const cache = path.join(process.env.HOME, '.gradle/caches/modules-2/files-2.1');
  kotlinDependencies = (await Promise.all([
    'io.kotest', 'io.github.classgraph', 'com.github.ajalt', 'org.opentest4j',
    'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.8.0',
    'org.jetbrains.kotlinx/kotlinx-coroutines-test-jvm/1.8.0',
    'org.jetbrains.kotlinx/kotlinx-coroutines-debug/1.8.0',
  ].map(group => files(path.join(cache, group))))).flat()
    .filter(file => file.endsWith('.jar') && !file.endsWith('-sources.jar')).join(':');
  return kotlinDependencies;
}
for (const target of targets) for (const machineBits of [32, 64]) for (const minify of [false, true]) {
  const directory = path.join(base, `${target}-${machineBits}-${minify}`);
  const plan = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target, machineBits, minify,
    sources: [{path: sourcePath, content: source}],
  }), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024}));
  assert.deepEqual(plan.diagnostics, [], target);
  for (const file of plan.files) {
    const destination = path.join(directory, file.path);
    await mkdir(path.dirname(destination), {recursive: true});
    await writeFile(destination, file.content);
  }
  const tests = plan.files.filter(file => file.placement === 'test');
  assert.ok(tests.some(file => /allPayloads|all_payloads/.test(file.content)), target);
  const sources = plan.files.filter(file => file.placement === 'source');
  assert.ok(sources.some(file => /positiveSum/.test(file.content)), target);
  let sequence = 0;
  async function run(command, args, options = {}) {
    const result = spawnSync(command, args, {cwd: directory, encoding: 'utf8',
      timeout: 120000, maxBuffer: 32 * 1024 * 1024, ...options});
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(directory, `check-${sequence++}.log`), log);
    assert.equal(result.error, undefined, `${target}: ${command}`);
    assert.equal(result.status, 0, `${target}/${machineBits}/${minify}: ${log}`);
    return log;
  }
  if (target === 'python') {
    const log = await run(process.env.LAWSPEC_PYTHON ?? 'python3.13',
      ['-m', 'pytest', '-q', '--tb=short', 'tests'], {env: {...process.env,
        PYTHONDONTWRITEBYTECODE: '1', PYTHONPATH: [path.join(directory, 'src'),
          path.join(directory, 'tests'), path.join(root, '.artifacts/python-data-deps')].join(':')}});
    assert.match(log, /[1-9][0-9]* passed/);
  } else if (target === 'javascript' || target === 'typescript') {
    await writeFile(path.join(directory, 'package.json'), '{"type":"module"}\n');
    await symlink(path.join(root, '.artifacts/lists/javascript/node_modules'),
      path.join(directory, 'node_modules')).catch(error => {
      if (error.code !== 'EEXIST') throw error;
    });
    if (target === 'typescript') {
      await writeFile(path.join(directory, 'tsconfig.json'), JSON.stringify({
        compilerOptions: {target: 'ES2022', module: 'NodeNext', strict: true,
          rootDir: '.', outDir: 'dist', skipLibCheck: true},
        include: ['src/**/*.ts', 'test/**/*.ts'],
      }));
      await run(process.execPath, [path.join(root, '.artifacts/web-data-deps/typescript/bin/tsc'), '-p', '.']);
    }
    const paths = tests.filter(file => /\.lawspec\.test\.(mjs|ts)$/.test(file.path))
      .map(file => target === 'typescript' ? 'dist/' + file.path.replace(/\.ts$/, '.js') : file.path);
    assert.ok(paths.length);
    const log = await run(process.execPath, ['--test', ...paths]);
    assert.match(log, /tests [1-9]/);
  } else if (target === 'go') {
    const rapid = path.join(execFileSync('go', ['env', 'GOMODCACHE'], {encoding: 'utf8'}).trim(),
      'pgregory.net/rapid@v1.2.0');
    await writeFile(path.join(directory, 'go.mod'),
      'module fixture\n\ngo 1.24.0\n\nrequire pgregory.net/rapid v1.2.0\nreplace pgregory.net/rapid => ' +
      JSON.stringify(rapid) + '\n');
    const log = await run('go', ['test', './...', '-count=1', '-v', '-rapid.seed=424242', '-rapid.nofailfile'],
      {env: {...process.env, GOCACHE: path.join(base, 'go-cache'), GOTOOLCHAIN: 'local', GOPROXY: 'off'}});
    assert.match(log, /PASS: Test/);
  } else if (target === 'java' || target === 'rust') {
    for (const [file, content] of Object.entries(templates(target))) {
      const destination = path.join(directory, file);
      await mkdir(path.dirname(destination), {recursive: true});
      await writeFile(destination, content);
    }
    if (target === 'java') {
      await run('mvn', ['-o', '-q', 'test']);
      const reports = (await files(path.join(directory, 'target/surefire-reports')))
        .filter(file => file.endsWith('.txt'));
      assert.ok(reports.length);
      for (const report of reports) assert.match(await readFile(report, 'utf8'), /Tests run: [1-9]/);
    } else {
      const log = await run('cargo', ['test', '--offline', '--quiet'],
        {env: {...process.env, CARGO_TARGET_DIR: path.join(base, 'rust-target')}});
      assert.match(log, /test result: ok/);
    }
  } else if (target === 'haskell') {
    assert.ok(process.env.LAWSPEC_GHC, 'Set LAWSPEC_GHC');
    const specs = tests.filter(file => file.path.endsWith('Spec.hs'))
      .map(file => /^module (\S+)/m.exec(file.content)[1]);
    assert.ok(specs.length);
    await writeFile(path.join(directory, 'Main.hs'), 'import Test.Hspec\n' +
      specs.map((name, i) => `import qualified ${name} as S${i}\n`).join('') +
      'main = hspec $ do\n' + specs.map((_, i) => `  S${i}.spec\n`).join(''));
    const packages = process.env.LAWSPEC_GHC_PACKAGE_DB ? ['-package-db', process.env.LAWSPEC_GHC_PACKAGE_DB] : [];
    await run(process.env.LAWSPEC_GHC, [...packages, '--make', 'Main.hs', '-isrc', '-itest',
      '-outputdir', 'build', '-o', 'check']);
    const log = await run(path.join(directory, 'check'), []);
    assert.match(log, /[1-9][0-9]* examples, 0 failures/);
  } else if (target === 'kotlin') {
    const classes = path.join(directory, 'classes');
    await mkdir(classes, {recursive: true});
    const java = sources.filter(file => file.path.endsWith('.java')).map(file => file.path);
    await run('javac', ['--release', '25', '-d', classes, ...java]);
    const kotlin = plan.files.filter(file => file.path.endsWith('.kt')).map(file => file.path);
    const specs = tests.filter(file => file.path.endsWith('LawSpecTest.kt')).map(file => {
      const packageName = /^package (\S+)/m.exec(file.content)?.[1];
      const name = /class (\w+)LawSpecTest/.exec(file.content)[1] + 'LawSpecTest';
      return (packageName ? packageName + '.' : '') + name;
    });
    assert.ok(specs.length);
    await writeFile(path.join(directory, 'Main.kt'), `
import io.kotest.engine.TestEngineLauncher
import io.kotest.engine.listener.CollectingTestEngineListener
@OptIn(io.kotest.common.KotestInternal::class)
fun main() {
    System.setProperty("kotest.framework.classpath.scanning.autoscan.disable", "true")
    val listener = CollectingTestEngineListener()
    val result = TestEngineLauncher(listener).withClasses(${specs.map(name => name + '::class').join(', ')}).launch()
    result.errors.forEach { it.printStackTrace() }
    val failed = listener.tests.values.filter { it.isErrorOrFailure } +
        listener.specs.values.filter { it.isErrorOrFailure }
    failed.take(5).forEach { it.errorOrNull?.printStackTrace() }
    check(result.errors.isEmpty() && !listener.errors && failed.isEmpty())
    check(listener.tests.isNotEmpty())
    println("Executed " + listener.tests.size + " generated Kotlin tests")
}
`);
    const classpath = classes + ':' + await kotlinClasspath();
    await run('kotlinc', ['-J-Xmx3g', '-jvm-target', '25', '-classpath', classpath,
      ...kotlin, 'Main.kt', '-d', 'checks.jar']);
    const log = await run('kotlin', ['-J-Xmx2g', '-classpath', `checks.jar:${classpath}`, 'MainKt']);
    assert.match(log, /Executed [1-9]/);
  } else assert.fail(`Unknown target: ${target}`);
  console.log(`${target}: recursive source passes ${machineBits} bits, minify=${minify}`);
}
