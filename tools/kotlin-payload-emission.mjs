// Execute JVM payload traversal through native Kotlin APIs and Kotest properties.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {access, mkdir, readFile, readdir, realpath, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_PAYLOAD_FIXTURE;
assert.ok(fixture, 'Set LAWSPEC_PAYLOAD_FIXTURE');
async function files(directory) {
  return (await Promise.all((await readdir(directory, {withFileTypes: true})).map(entry => {
    const file = path.join(directory, entry.name);
    return entry.isDirectory() ? files(file) : [file];
  }))).flat();
}
const cache = path.join(process.env.HOME, '.gradle/caches/modules-2/files-2.1');
const dependencies = (await Promise.all([
  'io.kotest', 'io.github.classgraph', 'com.github.ajalt', 'org.opentest4j',
  'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.8.0',
  'org.jetbrains.kotlinx/kotlinx-coroutines-test-jvm/1.8.0',
  'org.jetbrains.kotlinx/kotlinx-coroutines-debug/1.8.0',
].map(group => files(path.join(cache, group))))).flat()
  .filter(file => file.endsWith('.jar') && !file.endsWith('-sources.jar')).join(':');
const directory = path.join(root, '.artifacts/kotlin-payload-emission');
await mkdir(directory, {recursive: true});
let home = process.env.LAWSPEC_KOTLIN_HOME ?? path.dirname(path.dirname(
  await realpath(execFileSync('which', ['kotlinc'], {encoding: 'utf8'}).trim())));
if (!process.env.LAWSPEC_KOTLIN_HOME &&
    !await access(path.join(home, 'lib/kotlin-compiler.jar')).then(() => true, () => false))
  home = path.join(home, 'libexec');
execFileSync('javac', ['-cp', path.join(home, 'lib/*'), '-d', directory,
  path.join(root, 'tools/KotlinFormatCheck.java')]);
const nativeCheck = `
import lawspec.data.Tree
import lawspec.data.Pack
import lawspec.data.GenericPack
import lawspec.definitions.Payload
import lawspec.runtime.LawSpecKotlin as Native
import lawspec.runtime.LawSpecRuntime as Runtime
fun nativeCheck() {
    val symbols = mutableMapOf<String, Any>()
    val value: Tree<Byte> = Tree.NodeCase(listOf(Tree.LeafCase(2, -128), Tree.LeafCase(3, 0)))
    check(Payload.above(symbols, value, 1))
    check(!Payload.above(symbols, value, 2))
    check(Payload.positive(symbols, emptyList()))
    check(!Payload.positive(symbols, listOf(1, 0)))
    Payload.identity(symbols, Pack.PackCase(value))
    val error = runCatching {
        Payload.identity(symbols, Pack.PackCase(Tree.LeafCase(0, 0)))
    }.exceptionOrNull()
    check(error is IllegalArgumentException && error.message!!.contains("field refinement"))
    Payload.genericIdentity(symbols, GenericPack.GenericPackCase(value))
    fun symbol(id: String) = Native.Symbol(
        Runtime.symbol(id, "description", symbols).data() as Runtime.SymbolValue,
    )
    check(Payload.shared(symbols, listOf(symbol("shared"))))
    check(!Payload.shared(symbols, listOf(symbol("different"))))
}
`;
const launcher = `
import io.kotest.engine.TestEngineLauncher
import io.kotest.engine.listener.CollectingTestEngineListener
fun main() {
    NATIVE_CHECK
    System.setProperty("kotest.framework.classpath.scanning.autoscan.disable", "true")
    val listener = CollectingTestEngineListener()
    val result = TestEngineLauncher(listener).withClasses(PayloadLawSpecTest::class).launch()
    result.errors.forEach { it.printStackTrace() }
    val failed = listener.tests.values.filter { it.isErrorOrFailure } +
        listener.specs.values.filter { it.isErrorOrFailure }
    failed.take(5).forEach { it.errorOrNull?.printStackTrace() }
    check(result.errors.isEmpty() && !listener.errors && failed.isEmpty())
    check(listener.tests.isNotEmpty())
    println("Executed " + listener.tests.size + " Kotlin payload tests")
}
`;
for (const bits of [32, 64]) for (const builtins of [false, true]) {
  const readable = new Map();
  const rows = [];
  for (const compact of [false, true]) {
    const project = path.join(directory, `${bits}-${compact}-${builtins}`);
    execFileSync(fixture, [String(bits), compact ? 'True' : 'False', project, 'kotlin',
      ...(builtins ? ['builtins'] : [])]);
    const generated = await files(path.join(project, 'src'));
    const java = generated.filter(file => file.endsWith('.java'));
    const kotlin = generated.filter(file => file.endsWith('.kt'));
    for (const file of kotlin) {
      const relative = path.relative(project, file);
      if (!compact) readable.set(relative, file);
      else {
        assert.ok(readable.has(relative));
        rows.push([readable.get(relative), file, relative].join('\t'));
      }
    }
    const property = await readFile(path.join(project, 'src/test/kotlin/PayloadLawSpecTest.kt'), 'utf8');
    assert.match(property, /allPayloads/);
    assert.match(property, /checkAll/);
    const classes = path.join(project, 'classes');
    await mkdir(classes, {recursive: true});
    execFileSync('javac', ['--release', '25', '-d', classes, ...java], {encoding: 'utf8'});
    const main = path.join(project, 'Main.kt');
    await writeFile(main, launcher.replace('NATIVE_CHECK', builtins ? '' : 'nativeCheck()'));
    if (!builtins) {
      const check = path.join(project, 'NativeCheck.kt');
      await writeFile(check, nativeCheck);
      kotlin.push(check);
    }
    const jar = path.join(project, 'checks.jar');
    const classpath = `${classes}:${dependencies}`;
    execFileSync('kotlinc', ['-J-Xmx3g', '-jvm-target', '25', '-classpath', classpath,
      ...kotlin, main, '-d', jar], {encoding: 'utf8', maxBuffer: 16 * 1024 * 1024});
    const result = spawnSync('kotlin', ['-J-Xmx2g', '-classpath', `${jar}:${classpath}`, 'MainKt'],
      {encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, timeout: 60000});
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(project, 'check.log'), log);
    assert.equal(result.error, undefined);
    assert.equal(result.status, 0, log);
    if (bits === 64 && builtins && !compact) {
      const schema = java.find(file => file.endsWith('/LawSpecSchema.java'));
      const source = await readFile(schema, 'utf8');
      const operation = 'walkPayload(new PayloadApplication(type.name(), arguments), checked, predicates)';
      assert.ok(source.includes(operation));
      const mutant = path.join(project, 'mutant');
      await mkdir(mutant, {recursive: true});
      const mutantSource = path.join(mutant, 'LawSpecSchema.java');
      await writeFile(mutantSource, source.replace(operation, 'true'));
      execFileSync('javac', ['--release', '25', '-cp', classes, '-d', mutant, mutantSource],
        {encoding: 'utf8'});
      const rejected = spawnSync('kotlin', ['-J-Xmx2g', '-classpath',
        `${jar}:${mutant}:${classpath}`, 'MainKt'],
        {encoding: 'utf8', maxBuffer: 16 * 1024 * 1024, timeout: 60000});
      const rejection = (rejected.stdout ?? '') + (rejected.stderr ?? '');
      await writeFile(path.join(project, 'mutant.log'), rejection);
      assert.equal(rejected.error, undefined);
      assert.notEqual(rejected.status, 0, 'Kotest must reject an accept-all payload traversal');
      assert.match(rejection, /AssertionError/);
    }
    console.log(`Kotlin payload execution: ${bits}, compact=${compact}, builtins=${builtins}`);
  }
  const manifest = path.join(directory, `${bits}-${builtins}.tsv`);
  await writeFile(manifest, rows.join('\n') + '\n');
  execFileSync('java', ['-cp', directory + path.delimiter + path.join(home, 'lib/*'),
    'KotlinFormatCheck', manifest], {stdio: 'inherit'});
}
console.log('Kotlin payload native APIs and properties pass eight configurations, style checks and compact syntax-tree parity');
