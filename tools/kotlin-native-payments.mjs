import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const scaffold = process.env.LAWSPEC_GENERATOR_STUBS === '1';
const nativeGenerators = scaffold || process.env.LAWSPEC_NATIVE_GENERATORS === '1';
const {createCompiler} = await import('../npm/api.mjs');
const wasm = await createCompiler();
assert.ok(compiler, 'Set LAWSPEC_CORE');
const cache = path.join(process.env.HOME, '.gradle/caches/modules-2/files-2.1');
async function jars(directory) {
  const entries = await readdir(directory, {withFileTypes: true});
  return (await Promise.all(entries.map(entry => entry.isDirectory()
    ? jars(path.join(directory, entry.name)) : [path.join(directory, entry.name)])))
    .flat().filter(file => file.endsWith('.jar') && !file.endsWith('-sources.jar'));
}
const dependencies = (await Promise.all([
  'io.kotest', 'io.github.classgraph', 'com.github.ajalt', 'org.opentest4j',
  'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.8.0',
  'org.jetbrains.kotlinx/kotlinx-coroutines-test-jvm/1.8.0',
  'org.jetbrains.kotlinx/kotlinx-coroutines-debug/1.8.0',
].map(group => jars(path.join(cache, group))))).flat().join(':');
const paymentSource = await readFile(path.join(root, 'examples/specs/payments.lawspec'), 'utf8');
const shapesSource = await readFile(path.join(root, 'test/fixtures/native_shapes.lawspec'), 'utf8');
const paymentBindings = JSON.parse(await readFile(path.join(root, 'test/fixtures/native-payments/bindings-kotlin.json'), 'utf8'));
const shapeBindings = JSON.parse(await readFile(path.join(root, 'test/fixtures/native-shapes/bindings-kotlin.json'), 'utf8'));
for (const machineBits of (process.env.LAWSPEC_MACHINE_BITS ?? '32,64').split(',').map(Number)) {
  for (const minify of [false, true]) {
    const directory = path.join(root, `.artifacts/kotlin-native-payments/${machineBits}-${minify}${nativeGenerators ? '-generators' : ''}${scaffold ? '-stubs' : ''}`);
    const request = {
      schemaVersion: 4, method: 'planGeneration', target: 'kotlin', machineBits, minify,
      ...(machineBits === 32 ? {sourceDir: 'library/native', testDir: 'checks/generated'} : {}),
      nativeBindings: {types: [...paymentBindings.types, ...shapeBindings.types],
        functions: [...paymentBindings.functions, ...shapeBindings.functions],
        ...(nativeGenerators ? {generators: [
          {type: 'example.payments::type::Money', factory: ['domain', 'PaymentGenerators', 'prices']},
          {type: 'native.shapes::type::Box', factory: ['domain', 'PaymentGenerators', 'boxes']},
          {type: 'Int8', factory: ['domain', 'PaymentGenerators', 'bytes']},
          {type: 'Text', factory: ['domain', 'PaymentGenerators', 'texts']},
          {type: 'native.shapes::type::Stamp', factory: ['domain', 'PaymentGenerators', 'seals']},
        ]} : {})},
      generation: {exhaustiveLimit: 1},
      sources: [{path: 'payments.lawspec', content: paymentSource}, {path: 'shapes.lawspec', content: shapesSource},
        ...(nativeGenerators ? [{path:'refined.lawspec', content:
          'unit native.refined\nlaw `refined input` is definition is `for all` (x :: Int8 where x > 5) . x = x end end\n' +
          'law `native text` is definition is `for all` (x :: Text) . x = x end end'}] : [])],
    };
    if (scaffold) for (const generator of request.nativeBindings.generators) generator.stub = true;
    const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify(request),
      encoding: 'utf8', maxBuffer: 64 * 1024 * 1024}));
    assert.deepEqual(await wasm.planGeneration(request), result, 'native/WASM Kotlin binding parity');
    assert.deepEqual(result.diagnostics, []);
    const kotlinFiles = [], javaFiles = [], specs = [];
    for (const file of result.files) {
      const destination = path.join(directory, file.path);
      await mkdir(path.dirname(destination), {recursive: true});
      if (!file.path.endsWith('/native/Refined.kt') && !(scaffold && file.path.endsWith('/domain/PaymentGenerators.kt')))
        assert.notEqual(file.ownership, 'user', `unexpected manual adapter: ${file.path}`);
      await writeFile(destination, file.content);
      if (destination.endsWith('.java')) javaFiles.push(destination);
      if (destination.endsWith('.kt')) kotlinFiles.push(destination);
      const spec = file.content.match(/class (\w+LawSpecTest) : StringSpec/);
      if (spec) {
        const packageName = file.content.match(/^package ([\w.]+)/m)?.[1];
        specs.push(packageName ? `${packageName}.${spec[1]}` : spec[1]);
      }
    }
    const domainPath = path.join(directory, 'PaymentsDomain.kt');
    const domainSource = await readFile(path.join(root, 'test/fixtures/native-payments/PaymentsDomain.kt'), 'utf8');
    await writeFile(domainPath, domainSource);
    kotlinFiles.push(domainPath, path.join(root, 'test/fixtures/native-shapes/Shapes.kt'));
    const classes = path.join(directory, 'classes');
    await mkdir(classes, {recursive: true});
    execFileSync('javac', ['--release', '25', '-d', classes, ...javaFiles], {stdio: 'inherit'});
    if (scaffold) {
      const stub = result.files.find(file => file.path.endsWith('/domain/PaymentGenerators.kt'));
      assert.equal(stub.ownership, 'user');
      const main = path.join(directory, 'ScaffoldMain.kt');
      await writeFile(main, `import io.kotest.property.Arb
import io.kotest.property.arbitrary.constant
fun main() {
    try {
        domain.PaymentGenerators.prices()
        error("factory did not fail")
    } catch (error: NotImplementedError) {
        check(error.message!!.contains("Implement generator for"))
    }
    try {
        domain.PaymentGenerators.boxes(Arb.constant(1))
        error("generic factory did not fail")
    } catch (error: NotImplementedError) {
        check(error.message!!.contains("Implement generator for"))
    }
}
`);
      const stubJar = path.join(directory, 'scaffold.jar');
      const compiled = spawnSync('kotlinc', ['-J-Xmx3g', '-jvm-target', '25', '-classpath', `${classes}:${dependencies}`,
        ...kotlinFiles, main, '-d', stubJar], {encoding:'utf8',maxBuffer:32*1024*1024});
      assert.equal(compiled.status,0,compiled.stdout+compiled.stderr);
      execFileSync('kotlin',['-classpath',`${stubJar}:${classes}:${dependencies}`,'ScaffoldMainKt'],{encoding:'utf8'});
      await writeFile(path.join(directory,stub.path),await readFile(path.join(root,'test/fixtures/native-payments/PaymentGenerators.kt')));
      console.log(`Kotlin ${machineBits}, minify=${minify}: scaffolds compile and fail explicitly`);
    }
    if (nativeGenerators) {
      if (!scaffold) kotlinFiles.push(path.join(root, 'test/fixtures/native-payments/PaymentGenerators.kt'));
      kotlinFiles.push(path.join(root, 'test/fixtures/native-payments/NativeGeneratorContractsCheck.kt'));
    }
    const launcher = path.join(directory, 'Main.kt');
    await writeFile(launcher, `import io.kotest.engine.TestEngineLauncher
import io.kotest.engine.listener.CollectingTestEngineListener
fun main() {
  System.setProperty("kotest.framework.classpath.scanning.autoscan.disable", "true")
  var total = 0
  for (spec in listOf(${specs.map(spec => `${spec}::class`).join(', ')})) {
    ${nativeGenerators ? 'domain.PaymentGenerators.byteSamples.set(0)' : ''}
    val listener = CollectingTestEngineListener()
    val result = TestEngineLauncher(listener).withClasses(spec).launch()
    result.errors.forEach { it.printStackTrace() }
    val failed = listener.tests.values.filter { it.isErrorOrFailure } + listener.specs.values.filter { it.isErrorOrFailure }
    failed.take(5).forEach { it.errorOrNull?.printStackTrace() }
    check(result.errors.isEmpty() && !listener.errors && failed.isEmpty() && listener.tests.isNotEmpty()) { "generated tests failed" }
    ${nativeGenerators ? `if (spec.simpleName == "RefinedLawSpecTest") {
      check(domain.PaymentGenerators.byteSamples.get() > 0) { "refined scalar bypassed its native factory" }
    }` : ''}
    total += listener.tests.size
  }
  ${nativeGenerators ? `domain.checkNativeGenerators(${machineBits})` : ''}
  println("Executed " + total + " generated Kotlin tests")
}
`);
    const projectJar = path.join(directory, 'project.jar');
    const classpath = `${classes}:${dependencies}`;
    const built = spawnSync('kotlinc', ['-J-Xmx3g', '-jvm-target', '25', '-classpath', classpath,
      ...kotlinFiles, launcher, '-d', projectJar], {encoding: 'utf8', maxBuffer: 32 * 1024 * 1024});
    await writeFile(path.join(directory, 'build.log'), built.stdout + built.stderr);
    assert.equal(built.status, 0, built.stdout + built.stderr);
    async function run(label, extra = '') {
      const result = spawnSync('kotlin', ['-J-Xmx2g', '-classpath', `${extra}${projectJar}:${classpath}`, 'MainKt'],
        {cwd: directory, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024});
      await writeFile(path.join(directory, `${label}.log`), result.stdout + result.stderr);
      return result;
    }
    const correct = await run('correct');
    assert.equal(correct.status, 0, correct.stdout + correct.stderr);

    for (const [name, before, after] of [
      ['fee', 'BigDecimal("0.2")', 'BigDecimal("0.3")'],
      ['currency', ', price.unit)', ', CurrencyCode.Dollars)'],
      ['absence', '= payments', '= emptyList<Maybe<PaymentStatus>>()'],
    ]) {
      const changed = domainSource.replace(before, after);
      assert.notEqual(changed, domainSource);
      await writeFile(domainPath, changed);
      const jar = path.join(directory, `mutant-${name}.jar`);
      const compiled = spawnSync('kotlinc', ['-jvm-target', '25', '-classpath', `${projectJar}:${classpath}`,
        domainPath, '-d', jar], {encoding: 'utf8'});
      assert.equal(compiled.status, 0, compiled.stderr);
      const mutant = await run(`mutant-${name}`, `${jar}:`);
      assert.notEqual(mutant.status, 0, `mutant survived: ${name}`);
      assert.match(mutant.stdout + mutant.stderr, /expect |actual=/);
    }
    await writeFile(domainPath, domainSource);
    if (nativeGenerators) {
      const source = await readFile(path.join(root, 'test/fixtures/native-payments/PaymentGenerators.kt'), 'utf8');
      for (const [label, before, after, message] of [
        ['invalid-factory', 'Arb.constant("application text")', 'Arb.constant("\\ud800")', /native generator Text/],
        ['exhausted-refinement', 'Arb.int(6..20)', 'Arb.int(0..0)', /exhausted/],
      ]) {
        const broken = source.replace(before, after);
        assert.notEqual(broken, source);
        const factory = path.join(directory, 'PaymentGenerators.kt');
        await writeFile(factory, broken);
        const jar = path.join(directory, `${label}.jar`);
        const built = spawnSync('kotlinc', ['-jvm-target', '25', '-classpath', `${projectJar}:${classpath}`,
          factory, '-d', jar], {encoding:'utf8'});
        assert.equal(built.status, 0, built.stderr);
        const invalid = await run(label, `${jar}:`);
        assert.notEqual(invalid.status, 0);
        assert.match(invalid.stdout + invalid.stderr, message);
        if (label === 'invalid-factory') assert.match(invalid.stdout + invalid.stderr, /Property test failed/);
      }
    }
    console.log(`Kotlin native payments, recursive shapes${nativeGenerators ? ", generator contracts" : ""} and three adapter mutants passed: ${machineBits}, compact=${minify}`);
  }
}
