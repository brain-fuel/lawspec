import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {access, mkdir, readFile, readdir, realpath, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const formatter = process.env.LAWSPEC_GOOGLE_JAVA_FORMAT;
assert.ok(compiler && formatter, 'Set LAWSPEC_CORE and LAWSPEC_GOOGLE_JAVA_FORMAT');
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
].map(group => jars(path.join(cache, group))))).flat().join(path.delimiter);
const base = path.join(root, '.artifacts/kotlin-field-properties');
await mkdir(base, {recursive: true});
const source = (await readFile(path.join(root, 'test/fixtures/constructor_properties.lawspec'), 'utf8'))
  .replace('unit native.fields', 'unit fixture.fields') + `
sameSymbol :: Symbol -> Symbol -> Bool
law \`disjunctive fixture inputs\` is definition is
  \`for all\` (x :: Identity)
    (s :: Symbol where s == symbol("fixture", "same") || s == symbol("other", "same")) .
    sameSymbol s symbol("fixture", "same") = (s == symbol("fixture", "same"))
end end
`;
await writeFile(path.join(base, 'fields.lawspec'), source);
let home = process.env.LAWSPEC_KOTLIN_HOME ?? path.dirname(path.dirname(
  await realpath(execFileSync('which', ['kotlinc'], {encoding: 'utf8'}).trim())));
if (!await access(path.join(home, 'lib/kotlin-compiler.jar')).then(() => true, () => false))
  home = path.join(home, 'libexec');
const checker = path.join(base, 'checker');
await mkdir(checker, {recursive: true});
execFileSync('javac', ['-cp', path.join(home, 'lib/*'), '-d', checker,
  path.join(root, 'tools/KotlinFormatCheck.java')]);
const rows = [];
for (const machineBits of [32,64]) {
  const readable = new Map();
  for (const minify of [false,true]) {
    const directory = path.join(base, `${machineBits}-${minify ? 'compact' : 'pretty'}`);
    const sourceDir = machineBits === 32 ? 'library/native' : undefined;
    const testDir = machineBits === 32 ? 'checks/generated' : undefined;
    const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
      method: 'planGeneration', target: 'kotlin', machineBits, minify, sourceDir, testDir,
      sources: [{path: 'fields.lawspec', content: source}],
    }), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024}));
    assert.deepEqual(result.diagnostics, []);
    const java = [], kotlin = [];
    let adapterPath, adapterSource;
    const test = result.files.find(file => file.path.endsWith('/FieldsLawSpecTest.kt'));
    assert.ok(test.content.includes('law11Boundary0'));
    assert.ok(!test.content.includes('finite field domain property'));
    for (const file of result.files) {
      const destination = path.join(directory, file.path);
      await mkdir(path.dirname(destination), {recursive: true});
      await writeFile(destination, file.content);
      if (sourceDir) assert.ok(file.path.startsWith((file.placement === 'test' ? testDir : sourceDir) + '/'));
      if (file.path.endsWith('.java')) {
        java.push(destination);
        const formatted = execFileSync('java', ['-jar', formatter, destination], {encoding: 'utf8'});
        if (!minify) {
          assert.equal(file.content, formatted, file.path);
          readable.set(file.path, formatted);
        } else assert.equal(formatted, readable.get(file.path));
      } else {
        kotlin.push(destination);
        const audit = destination + '.generated.kt';
        await writeFile(audit, file.content);
        if (minify) rows.push([audit.replace('-compact/', '-pretty/'), audit, file.path].join('\t'));
      }
      if (file.ownership === 'user') {
        adapterPath = destination;
        adapterSource = file.content.replace(/TODO\("sameSymbol"\)/g, 'value0 == value1')
          .replace(/TODO\("echoAdapter"\)/g, 'value0');
        assert.doesNotMatch(adapterSource, /TODO\(/);
        await writeFile(destination, adapterSource);
      }
    }
    const classes = path.join(directory, 'classes');
    await mkdir(classes, {recursive: true});
    execFileSync('javac', ['--release', '25', '-d', classes, ...java]);
    const launcher = path.join(directory, 'Main.kt');
    await writeFile(launcher, `import io.kotest.engine.TestEngineLauncher
import io.kotest.engine.listener.CollectingTestEngineListener
fun main() {
  System.setProperty("kotest.framework.classpath.scanning.autoscan.disable", "true")
  val listener = CollectingTestEngineListener()
  val result = TestEngineLauncher(listener).withClasses(fixture.FieldsLawSpecTest::class).launch()
  result.errors.forEach { it.printStackTrace() }
  val failed = listener.tests.values.filter { it.isErrorOrFailure } + listener.specs.values.filter { it.isErrorOrFailure }
  failed.take(3).forEach { it.errorOrNull?.printStackTrace() }
  check(result.errors.isEmpty() && !listener.errors && failed.isEmpty() && listener.tests.isNotEmpty())
  println("Executed " + listener.tests.size + " Kotlin constructor tests")
}
`);
    const classpath = [classes, dependencies].join(path.delimiter);
    const jar = path.join(directory, 'project.jar');
    const run = async label => {
      const build = spawnSync('kotlinc', ['-J-Xmx3g', '-jvm-target', '25', '-classpath', classpath,
        ...kotlin, launcher, '-d', jar], {encoding: 'utf8', maxBuffer: 16 * 1024 * 1024});
      await writeFile(path.join(directory, `${label}-build.log`), (build.stdout ?? '') + (build.stderr ?? ''));
      assert.equal(build.status, 0, build.stderr);
      const result = spawnSync('kotlin', ['-J-Xmx2g', '-classpath', [jar, classpath].join(path.delimiter), 'MainKt'],
        {encoding: 'utf8', maxBuffer: 16 * 1024 * 1024});
      const log = (result.stdout ?? '') + (result.stderr ?? '');
      await writeFile(path.join(directory, `${label}.log`), log);
      return {...result, log};
    };
    const correct = await run('correct');
    assert.equal(correct.status, 0, correct.log);
    assert.ok(adapterPath);
    for (const [label, mutant] of [
      ['identity-mutant', adapterSource.replace(/(fun echoAdapter[^=]+=)\s*value0/, '$1 lawspec.data.Identity.IdentityCase(lawspec.runtime.LawSpecKotlin.Symbol("same"))')],
      ['disjunction-mutant', adapterSource.replace('value0 == value1', 'true')],
    ]) {
      assert.notEqual(mutant, adapterSource);
      try {
        await writeFile(adapterPath, mutant);
        const failed = await run(label);
        assert.notEqual(failed.status, 0, label);
        assert.match(failed.log, /AssertionError|field refinement/);
      } finally {
        await writeFile(adapterPath, adapterSource);
      }
    }
    const strategies = result.files.find(file => file.path.endsWith('/LawSpecKotlinStrategies.kt'));
    const strategyPath = path.join(directory, strategies.path);
    const runtime = await readFile(path.join(root, 'runtime/LawSpecKotlinStrategies.kt'), 'utf8');
    const errorMutant = runtime.replace('Checked(schema.validate(type, value, bits, symbols), null)',
      'Checked(null, IllegalArgumentException("forced predicate evaluation error"))');
    assert.notEqual(errorMutant, runtime);
    try {
      await writeFile(strategyPath, errorMutant);
      const failed = await run('evaluator-error');
      assert.notEqual(failed.status, 0);
      assert.match(failed.log, /forced predicate evaluation error/);
      assert.doesNotMatch(failed.log, /IndexOutOfBoundsException/);
    } finally {
      await writeFile(strategyPath, strategies.content);
    }
    console.log(`Public Kotlin constructor properties and mutants pass: ${machineBits}, minify=${minify}`);
  }
}
const manifest = path.join(base, 'format.tsv');
await writeFile(manifest, rows.join('\n') + '\n');
execFileSync('java', ['-cp', checker + path.delimiter + path.join(home, 'lib/*'), 'KotlinFormatCheck', manifest], {stdio: 'inherit'});
