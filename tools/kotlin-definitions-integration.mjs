import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, mkdtemp, readdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {planWrites, applyWrites} from '../npm/files.mjs';

const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const fixture = process.env.LAWSPEC_KOTLIN_DEFINITIONS_FIXTURE;
const formatter = process.env.LAWSPEC_GOOGLE_JAVA_FORMAT;
assert.ok(compiler && fixture && formatter, 'Set LAWSPEC_CORE, LAWSPEC_KOTLIN_DEFINITIONS_FIXTURE and LAWSPEC_GOOGLE_JAVA_FORMAT');
async function jars(directory) {
  const entries = await readdir(directory, {withFileTypes: true});
  return (await Promise.all(entries.map(entry => entry.isDirectory()
    ? jars(path.join(directory, entry.name)) : [path.join(directory, entry.name)])))
    .flat().filter(file => file.endsWith('.jar') && !file.endsWith('-sources.jar'));
}
const cache = path.join(process.env.HOME, '.gradle/caches/modules-2/files-2.1');
const dependencies = (await Promise.all([
  'io.kotest', 'io.github.classgraph', 'com.github.ajalt', 'org.opentest4j',
  'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.8.0',
  'org.jetbrains.kotlinx/kotlinx-coroutines-test-jvm/1.8.0',
  'org.jetbrains.kotlinx/kotlinx-coroutines-debug/1.8.0',
].map(group => jars(path.join(cache, group))))).flat().join(':');
const source = await readFile(path.join(root, 'test/fixtures/total_definitions.lawspec'), 'utf8');
const other = 'unit other\ndefinition genericIdentity (x :: a) :: a is x end\ndefinition genericCount (xs :: List a) :: BigInt is match xs with | Nil -> 0 | Cons head tail -> 1 + genericCount tail end end\nlaw `generic booleans` is definition is `for all` (xs :: List Bool) . genericCount xs = prelude.length xs end end\nlaw `generic texts` is definition is `for all` (xs :: List Text where genericCount xs > 0) . genericCount xs = prelude.length xs end end\ndefinition size (x :: Bool) :: Bool is genericIdentity x end\nlaw `identity` is definition is `for all` (x :: Bool where genericIdentity x) . size x = x end end';
for (const machineBits of (process.env.LAWSPEC_MACHINE_BITS ?? '32,64').split(',').map(Number)) {
  const custom = machineBits === 32;
  const javaRoot = custom ? 'library/native' : 'src/main/java';
  const kotlinRoot = custom ? 'library/native' : 'src/main/kotlin';
  const testRoot = custom ? 'checks/generated' : 'src/test/kotlin';
  const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target: 'kotlin', machineBits,
    ...(custom ? {sourceDir: kotlinRoot, testDir: testRoot} : {}),
    sources: [{path: 'total.lawspec', content: source}, {path: 'other.lawspec', content: other}],
  }), encoding: 'utf8', maxBuffer: 48 * 1024 * 1024}));
  assert.deepEqual(result.diagnostics, []);
  const directory = path.join(root, `.artifacts/kotlin-definitions/${machineBits}`);
  const kotlinFiles = [];
  const nativeFiles = [];
  const javaFiles = [];
  const specs = [];
  const generated = [];
  let adapterPath;
  let adapterSource;
  for (const file of result.files) {
    assert.ok(file.path.startsWith((file.placement === 'test' ? testRoot : file.path.endsWith('.java') ? javaRoot : kotlinRoot) + '/'));
    const destination = path.join(directory, file.path);
    await mkdir(path.dirname(destination), {recursive: true});
    let content = file.content;
    if (file.ownership === 'user') {
      assert.doesNotMatch(content, /fun (size|sumList|sumTree|increment|forward|divisible|machine)\(/);
      const bodies = {
        actualSum: 'value0.fold(java.math.BigInteger.ZERO) { sum, x -> sum + x.toInt().toBigInteger() }',
        actualIncrement: 'value0.toInt().toBigInteger() + java.math.BigInteger.ONE',
        actualTree: `when (value0) {
          is lawspec.data.Tree.LeafCase -> value0.value.toInt().toBigInteger()
          is lawspec.data.Tree.BranchCase -> actualTree(value0.left) + actualTree(value0.right)
        }`,
      };
      content = content.replace(/TODO\("(actual\w+)"\)/g, (_, name) => bodies[name]);
      assert.doesNotMatch(content, /TODO\(/);
      if (file.path.endsWith('/example/Total.kt')) {
        adapterPath = destination;
        adapterSource = content;
      }
    }
    await writeFile(destination, content);
    if (file.path.endsWith('.java')) javaFiles.push(destination);
    else {
      kotlinFiles.push(destination);
      if (file.placement === 'source') nativeFiles.push(destination);
    }
    if (file.path.endsWith('LawSpecTest.kt')) {
      const packageName = /package ([^;\n]+)/.exec(content)?.[1];
      const name = /class (\w+)LawSpecTest/.exec(content)[1] + 'LawSpecTest';
      specs.push(packageName ? `${packageName}.${name}` : name);
    }
    if (file.path.includes('/lawspec/definitions/') || file.path.endsWith('/LawSpecDefinitionBodies.java')) {
      assert.equal(file.ownership, 'generated');
      assert.equal(file.placement, 'source');
      assert.doesNotMatch(content, /kotest|TODO\(/);
      generated.push({file, destination, content});
      if (file.path.endsWith('.java')) {
        assert.equal(content, execFileSync('java', ['-jar', formatter, destination], {encoding: 'utf8'}));
      }
    }
  }
  assert.ok(adapterPath && generated.length === 3);
  const classes = path.join(directory, 'classes');
  await mkdir(classes, {recursive: true});
  execFileSync('javac', ['--release', '25', '-d', classes, ...javaFiles], {stdio: 'inherit'});
  const nativeCheck = path.join(directory, 'KotlinDefinitionsCheck.kt');
  await writeFile(nativeCheck, await readFile(path.join(root, 'test/runtime/KotlinDefinitionsCheck.kt'), 'utf8'));
  const nativeJar = path.join(directory, 'native.jar');
  execFileSync('kotlinc', ['-jvm-target', '25', '-classpath', classes, ...nativeFiles, nativeCheck, '-d', nativeJar], {encoding: 'utf8'});
  execFileSync('kotlin', ['-classpath', `${nativeJar}:${classes}`, 'KotlinDefinitionsCheckKt', String(machineBits)], {stdio: 'inherit'});
  for (const [i, invocation] of [
    'lawspec.definitions.example.Total.size(symbols, listOf("wrong"))',
    'lawspec.definitions.example.Total.sumTree(symbols, true)',
    'lawspec.definitions.example.Total.maybeDefault(symbols, lawspec.runtime.LawSpecRuntime.Just(true))',
    'lawspec.definitions.example.Total.absent(symbols, lawspec.runtime.LawSpecKotlin.Optional.Present(true))',
  ].entries()) {
    const badPath = path.join(directory, 'BadDefinitionCall.kt');
    await writeFile(badPath, `fun bad() { val symbols = mutableMapOf<String, Any>(); ${invocation} }`);
    const bad = spawnSync('kotlinc', ['-jvm-target', '25', '-classpath', `${nativeJar}:${classes}`, badPath, '-d', path.join(directory, 'bad.jar')], {encoding: 'utf8'});
    assert.notEqual(bad.status, 0, `native type mismatch ${i} must be rejected`);
    assert.match(bad.stderr, /mismatch|cannot infer type|inference failed/);
  }
  const launcher = path.join(directory, 'Main.kt');
  await writeFile(launcher, `import io.kotest.engine.TestEngineLauncher
import io.kotest.engine.listener.CollectingTestEngineListener
fun main() {
  System.setProperty("kotest.framework.classpath.scanning.autoscan.disable", "true")
  val listener = CollectingTestEngineListener()
  val result = TestEngineLauncher(listener).withClasses(${specs.map(spec => `${spec}::class`).join(', ')}).launch()
  result.errors.forEach { it.printStackTrace() }
  val failed = listener.tests.values.filter { it.isErrorOrFailure } + listener.specs.values.filter { it.isErrorOrFailure }
  failed.take(5).forEach { it.errorOrNull?.printStackTrace() }
  check(result.errors.isEmpty() && !listener.errors && failed.isEmpty() && listener.tests.isNotEmpty())
  println("Executed " + listener.tests.size + " generated Kotlin tests")
}
`);
  const projectJar = path.join(directory, 'project.jar');
  const classpath = `${classes}:${dependencies}`;
  function compile() {
    const build = spawnSync('kotlinc', ['-J-Xmx3g', '-jvm-target', '25', '-classpath', classpath, ...kotlinFiles, launcher, '-d', projectJar], {encoding: 'utf8', maxBuffer: 24 * 1024 * 1024});
    assert.equal(build.status, 0, build.stdout + build.stderr);
  }
  compile();
  async function run(label, extra = '') {
    const result = spawnSync('kotlin', ['-J-Xmx2g', '-classpath', `${extra}${projectJar}:${classpath}`, 'MainKt'], {encoding: 'utf8', maxBuffer: 24 * 1024 * 1024});
    await writeFile(path.join(directory, `${label}.log`), result.stdout + result.stderr);
    return result;
  }
  const correct = await run('correct');
  assert.equal(correct.status, 0, correct.stdout + correct.stderr);
  const compactPlan = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target: 'kotlin', machineBits, minify: true,
    ...(custom ? {sourceDir: kotlinRoot, testDir: testRoot} : {}),
    sources: [{path: 'total.lawspec', content: source}, {path: 'other.lawspec', content: other}],
  }), encoding: 'utf8', maxBuffer: 48 * 1024 * 1024}));
  assert.deepEqual(compactPlan.diagnostics, []);
  for (const file of compactPlan.files.filter(file => file.ownership === 'generated')) {
    await writeFile(path.join(directory, file.path), file.content);
  }
  execFileSync('javac', ['--release', '25', '-d', classes, ...javaFiles], {stdio: 'inherit'});
  compile();
  const compactProperties = await run('compact-properties');
  assert.equal(compactProperties.status, 0, compactProperties.stdout + compactProperties.stderr);
  for (const file of result.files.filter(file => file.ownership === 'generated')) {
    await writeFile(path.join(directory, file.path), file.content);
  }
  execFileSync('javac', ['--release', '25', '-d', classes, ...javaFiles], {stdio: 'inherit'});
  compile();
  for (const [label, from, to] of [
    ['sum', 'value0.fold(java.math.BigInteger.ZERO) { sum, x -> sum + x.toInt().toBigInteger() }', 'java.math.BigInteger.ZERO'],
    ['overflow', 'value0.toInt().toBigInteger() + java.math.BigInteger.ONE', '(value0 + 1).toByte().toInt().toBigInteger()'],
    ['tree', 'actualTree(value0.left) + actualTree(value0.right)', 'java.math.BigInteger.ZERO'],
  ]) {
    const mutation = adapterSource.replace(from, to);
    assert.notEqual(mutation, adapterSource);
    await writeFile(adapterPath, mutation);
    const jar = path.join(directory, `${label}.jar`);
    execFileSync('kotlinc', ['-jvm-target', '25', '-classpath', `${projectJar}:${classpath}`, adapterPath, '-d', jar], {encoding: 'utf8'});
    const mutant = await run(label, `${jar}:`);
    assert.notEqual(mutant.status, 0, `mutant exposed: ${label}`);
    assert.match(mutant.stdout + mutant.stderr, /Assertion|Property failed/);
  }
  await writeFile(adapterPath, adapterSource);
  const sourcePath = path.join(directory, 'total.lawspec');
  const otherPath = path.join(directory, 'other.lawspec');
  await writeFile(sourcePath, source);
  await writeFile(otherPath, other);
  execFileSync(fixture, [String(machineBits), directory, javaRoot, kotlinRoot, sourcePath, otherPath]);
  assert.ok((await readFile(generated[0].destination, 'utf8')).length < generated[0].content.length);
  execFileSync('javac', ['--release', '25', '-d', classes, ...javaFiles], {stdio: 'inherit'});
  compile();
  const compact = await run('compact');
  assert.equal(compact.status, 0, compact.stdout + compact.stderr);
  for (const file of generated) await writeFile(file.destination, file.content);
  const regeneration = await mkdtemp(path.join(directory, 'regeneration-'));
  await applyWrites([await planWrites(regeneration, result.files)]);
  const adapter = result.files.find(file => file.path.endsWith('/example/Total.kt') && file.ownership === 'user');
  await writeFile(path.join(regeneration, adapter.path), adapterSource);
  assert.equal((await planWrites(regeneration, result.files)).changes.length, 0);
  await writeFile(path.join(regeneration, generated[0].file.path), '// edited generated definition\n');
  await assert.rejects(planWrites(regeneration, result.files), /edited generated file/);
  console.log(`Kotlin total definitions, native types, properties, compact source, ownership and mutants passed: ${machineBits}`);
}
