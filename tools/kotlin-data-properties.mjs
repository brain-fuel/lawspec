import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const minify = process.env.LAWSPEC_MINIFY === '1';
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
const source = await readFile(path.join(root, 'examples/specs/data_types.lawspec'), 'utf8') + `
echoTree :: Tree Int8 -> Tree Int8
echoPair :: Pair Int8 Bool -> Pair Int8 Bool
echoNested :: List (Maybe (Tree Int8)) -> List (Maybe (Tree Int8))
echoRaw :: Pair CodeUnit16 Bytes -> Pair CodeUnit16 Bytes
getMaybe :: Pair (Maybe Int8) Bool -> Maybe Int8
contractEcho :: (x :: Tree Int8) -> (result :: Tree Int8 where result == x)
law \`native tree\` is definition is \`for all\` (x :: Tree Int8) . echoTree x = x end end
law \`native product\` is definition is \`for all\` (x :: Pair Int8 Bool) . echoPair x = x end end
law \`native nested containers\` is definition is \`for all\` (x :: List (Maybe (Tree Int8))) . echoNested x = x end end
law \`native raw values\` is definition is \`for all\` (x :: Pair CodeUnit16 Bytes) . echoRaw x = x end end
law \`native fields compose\` is definition is \`for all\` (x :: Pair (Maybe Int8) Bool) . getMaybe x = (match x with | Pair first second -> first end) end end
`;
for (const scenario of (process.env.LAWSPEC_SCENARIOS ?? 'data,collections,scalars,refinements').split(',')) {
  for (const machineBits of (process.env.LAWSPEC_MACHINE_BITS ?? '32,64').split(',').map(Number)) {
    const sourceDir = machineBits === 32 ? 'library/native' : '';
    const testDir = machineBits === 32 ? 'checks/generated' : '';
    const sources = [{path: 'main.lawspec', content: scenario === 'data' ? source :
      await readFile(path.join(root, `examples/specs/${scenario === 'scalars' ? 'scalar_adapters' : scenario === 'refinements' ? 'refinements' : 'collections'}.lawspec`), 'utf8')}];
    if (scenario === 'data') sources.push({path: 'matching.lawspec', content:
      await readFile(path.join(root, 'examples/specs/matching.lawspec'), 'utf8')});
    if (scenario === 'data' && machineBits === 32) sources.push({path: 'finite.lawspec', content:
      await readFile(path.join(root, 'examples/specs/finite_data.lawspec'), 'utf8')});
    if (scenario === 'scalars') {
      for (const name of ['scalar_catalog', 'scalars']) sources.push({path: `${name}.lawspec`, content:
        await readFile(path.join(root, `examples/specs/${name}.lawspec`), 'utf8')});
      const vectors = JSON.parse(await readFile(path.join(root, 'test/scalar-vectors.json'), 'utf8'));
      sources.push({path: 'conformance.lawspec', content: 'unit conformance\n' + vectors.map((vector, index) =>
        `law \`vector ${index}\` is definition is \`for all\` (marker :: Unit) . ${vector.expression} = ${vector.expected} end end`).join('\n')});
    }
    sources.push({path: 'sum_refinements.lawspec', content:
      await readFile(path.join(root, 'examples/specs/sum_refinements.lawspec'), 'utf8')});
    sources.push({path: 'list_refinements.lawspec', content:
      await readFile(path.join(root, 'examples/specs/list_refinements.lawspec'), 'utf8')});
    const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
      method: 'planGeneration', target: 'kotlin', machineBits, minify, sources,
      ...(sourceDir ? {sourceDir, testDir} : {}),
    }), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024}));
    assert.deepEqual(result.diagnostics, []);
    const directory = path.join(root, `.artifacts/kotlin-data-properties${minify ? '-compact' : ''}/${scenario}/${machineBits}`);
    const kotlinFiles = [];
    const javaFiles = [];
    const specs = [];
    let adapterPath;
    let adapterSource;
    const pair = machineBits === 32 && scenario === 'data' ? 'ExampleDataTypesTypePair' : 'Pair';
    for (const file of result.files) {
      if (sourceDir) assert.ok(file.path.startsWith(`${file.placement === 'test' ? testDir : sourceDir}/`));
      const destination = path.join(directory, file.path);
      await mkdir(path.dirname(destination), {recursive: true});
      let content = file.content;
      if (file.ownership === 'user') {
        content = content.replace(/TODO\("(\w+)"\)/g,
          (_, name) => {
            const bodies = {
              reverse: 'value0.reversed()', sort: 'value0.sorted()',
              sorted: 'value0 == value0.sorted()',
              permutation: 'value0.sorted() == value1.sorted()',
              getMaybe: `(value0 as lawspec.data.${pair}.PairCase).first`,
              successor: 'value0.toInt().toBigInteger() + java.math.BigInteger.ONE',
              addDecimal: 'value0 + value1', sameSymbol: 'value0 == value1',
              add: 'value0.toInt().toBigInteger() + value1.toInt().toBigInteger()',
              count: 'value0.codePointCount(0, value0.length).toBigInteger()',
            };
            return bodies[name] ?? 'value0';
          });
        if (content.includes('fun echoTree(') || content.includes('fun echoEither(') || content.includes('fun successor(')) {
          adapterPath = destination;
          adapterSource = content;
        }
      }
      await writeFile(destination, content);
      if (destination.endsWith('.java')) javaFiles.push(destination);
      if (destination.endsWith('.kt')) kotlinFiles.push(destination);
      const spec = content.match(/class (\w+LawSpecTest) : StringSpec/);
      if (spec) {
        const packageName = content.match(/^package ([\w.]+)/m)?.[1];
        specs.push(packageName ? `${packageName}.${spec[1]}` : spec[1]);
      }
    }
    const classes = path.join(directory, 'classes');
    await mkdir(classes, {recursive: true});
    execFileSync('javac', ['--release', '25', '-d', classes, ...javaFiles], {stdio: 'inherit'});
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
  check(result.errors.isEmpty() && !listener.errors && failed.isEmpty() && listener.tests.isNotEmpty()) { "generated tests failed" }
  println("Executed " + listener.tests.size + " generated Kotlin tests")
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
    const mutations = scenario === 'data' ? [
      ['tree', /fun echoTree([^=]+)=\s*value0\b/, 'fun echoTree$1 = lawspec.data.Tree.BranchCase(emptyList())'],
      ['pair', /fun echoPair([^=]+)=\s*value0\b/, `fun echoPair$1 = lawspec.data.${pair}.PairCase(0.toByte(), false)`],
      ['nested', /fun echoNested([^=]+)=\s*value0\b/, 'fun echoNested$1 = emptyList()'],
      ['raw', /fun echoRaw([^=]+)=\s*value0\b/, `fun echoRaw$1 = lawspec.data.${pair}.PairCase(0.toChar(), byteArrayOf())`],
      ['contract', /fun contractEcho([^=]+)=\s*value0\b/, 'fun contractEcho$1 = lawspec.data.Tree.LeafCase(0.toByte())'],
    ] : scenario === 'refinements' ? [
      ['overflow', 'value0.toInt().toBigInteger() + value1.toInt().toBigInteger()', '(value0 + value1).toByte().toInt().toBigInteger()'],
      ['precision', /fun preserve([^=]+)=\s*value0\b/, 'fun preserve$1 = java.math.BigDecimal(value0.toDouble()).toBigInteger()'],
      ['refinement', /fun positive([^=]+)=\s*value0\b/, 'fun positive$1 = 0.toByte()'],
      ['standalone', 'value0.codePointCount(0, value0.length).toBigInteger()', 'java.math.BigInteger.ZERO'],
    ] : scenario === 'scalars' ? [
      ['overflow', 'value0.toInt().toBigInteger() + java.math.BigInteger.ONE', '(value0 + 1).toByte().toInt().toBigInteger()'],
      ['symbol', 'value0 == value1', 'value0.description == value1.description'],
      ['presence', /fun echoPresence([^=]+)=\s*value0\b/, 'fun echoPresence$1 = lawspec.runtime.LawSpecKotlin.Optional.Undefined()'],
      ['raw', /fun echoRaw([^=]+)=\s*value0\b/, 'fun echoRaw$1 = ""'],
    ] : [
      ['reverse', 'value0.reversed()', 'emptyList()'],
      ['sort', 'value0.sorted()', 'value0.map { 0 }'],
      ['maybe', /fun echoMaybe([^=]+)=\s*value0\b/, 'fun echoMaybe$1 = LawSpecRuntime.Nothing()'],
      ['either', /fun echoEither([^=]+)=\s*value0\b/, 'fun echoEither$1 = LawSpecRuntime.Right(LawSpecRuntime.Nothing())'],
      ['nested', /fun echoNested([^=]+)=\s*value0\b/, 'fun echoNested$1 = emptyList()'],
    ];
    for (const [name, before, after] of mutations) {
      const changed = adapterSource.replace(before, after);
      assert.notEqual(changed, adapterSource, name);
      await writeFile(adapterPath, changed);
      const jar = path.join(directory, `mutant-${name}.jar`);
      const compiled = spawnSync('kotlinc', ['-jvm-target', '25', '-classpath', `${projectJar}:${classpath}`,
        adapterPath, '-d', jar], {encoding: 'utf8'});
      assert.equal(compiled.status, 0, compiled.stderr);
      const mutant = await run(`mutant-${name}`, `${jar}:`);
      assert.notEqual(mutant.status, 0, `mutant survived: ${name}`);
      assert.match(mutant.stdout + mutant.stderr, /expect |postcondition|actual=/);
    }
    await writeFile(adapterPath, adapterSource);
    console.log(`Kotlin ${scenario} properties and ${mutations.length} mutants passed: ${machineBits}`);
  }
}
