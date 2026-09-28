import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, mkdtemp, readFile, readdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {templates} from '../npm/templates.mjs';
import {planWrites, applyWrites} from '../npm/files.mjs';

const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const formatter = process.env.LAWSPEC_GOOGLE_JAVA_FORMAT;
assert.ok(compiler && formatter, 'Set LAWSPEC_CORE and LAWSPEC_GOOGLE_JAVA_FORMAT');
const source = await readFile(path.join(root, 'test/fixtures/total_definitions.lawspec'), 'utf8');
const other = 'unit other\ndefinition genericIdentity (x :: a) :: a is x end\ndefinition genericCount (xs :: List a) :: BigInt is match xs with | Nil -> 0 | Cons head tail -> 1 + genericCount tail end end\nlaw `generic booleans` is definition is `for all` (xs :: List Bool) . genericCount xs = prelude.length xs end end\nlaw `generic texts` is definition is `for all` (xs :: List Text where genericCount xs > 0) . genericCount xs = prelude.length xs end end\ndefinition size (x :: Bool) :: Bool is genericIdentity x end\nlaw `identity` is definition is `for all` (x :: Bool where genericIdentity x) . size x = x end end';
const profiles = process.env.LAWSPEC_MACHINE_BITS ? [Number(process.env.LAWSPEC_MACHINE_BITS)] : [32, 64];
for (const machineBits of profiles) {
  const sourceDir = machineBits === 32 ? 'generated/source' : 'src/main/java';
  const testDir = machineBits === 32 ? 'generated/tests' : 'src/test/java';
  const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target: 'java', machineBits, sourceDir, testDir,
    sources: [{path: 'total.lawspec', content: source}, {path: 'other.lawspec', content: other}],
  }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
  assert.deepEqual(result.diagnostics, []);
  const directory = path.join(root, `.artifacts/java-definitions/${machineBits}`);
  await mkdir(directory, {recursive: true});
  const scaffold = templates('java');
  await writeFile(path.join(directory, 'pom.xml'), scaffold['pom.xml'].replace('<build>',
    `<build><sourceDirectory>${sourceDir}</sourceDirectory><testSourceDirectory>${testDir}</testSourceDirectory>`));
  let adapterPath;
  let adapterSource;
  const generated = [];
  for (const file of result.files) {
    assert.ok(file.path.startsWith(`${file.placement === 'test' ? testDir : sourceDir}/`));
    const destination = path.join(directory, file.path);
    await mkdir(path.dirname(destination), {recursive: true});
    let content = file.content;
    if (file.ownership === 'user') {
      assert.doesNotMatch(content, /public static [^\n]+\b(size|sumList|sumTree|increment|forward|divisible|machine)\(/);
      const bodies = {
        actualSum: 'return value0.stream().map(n -> java.math.BigInteger.valueOf(n)).reduce(java.math.BigInteger.ZERO, java.math.BigInteger::add);',
        actualIncrement: 'return java.math.BigInteger.valueOf(value0).add(java.math.BigInteger.ONE);',
        actualTree: `return switch (value0) {
          case lawspec.data.Tree.LeafCase leaf -> java.math.BigInteger.valueOf(leaf.value);
          case lawspec.data.Tree.BranchCase branch -> actualTree(branch.left).add(actualTree(branch.right));
        };`,
      };
      content = content.replace(/throw new UnsupportedOperationException\("(actual\w+) -> [^"\n]+"\);/g,
        (_, name) => bodies[name]);
      assert.doesNotMatch(content, /UnsupportedOperationException/);
      if (file.path.endsWith('/example/Total.java')) {
        adapterPath = destination;
        adapterSource = content;
      }
    }
    await writeFile(destination, content);
    if (file.path.endsWith('LawSpecTest.java')) {
      const formatted = execFileSync('java', ['-jar', formatter, '-'], {
        input: content, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
      });
      if (formatted !== content) await writeFile(destination + '.formatted', formatted);
      assert.equal(content, formatted, `Google Java Format differs: ${destination}`);
    }
    if (file.path.includes('/lawspec/definitions/') || file.path.endsWith('/LawSpecDefinitionBodies.java')) {
      assert.equal(file.ownership, 'generated');
      assert.equal(file.placement, 'source');
      assert.doesNotMatch(content, /org.junit|jetCheck|UnsupportedOperationException/);
      generated.push({file, destination, content});
      const formatted = execFileSync('java', ['-jar', formatter, destination], {encoding: 'utf8'});
      await writeFile(destination + '.formatted', formatted);
      {
        assert.ok(content === formatted, `Google Java Format differs: ${destination}.formatted`);
      }
    }
  }
  assert.ok(adapterPath && generated.length === 3);
  const check = path.join(directory, 'JavaDefinitionsCheck.java');
  await writeFile(check, await readFile(path.join(root, 'test/runtime/JavaDefinitionsCheck.java'), 'utf8'));
  async function run(label, args = []) {
    const result = spawnSync('mvn', ['-o', '-q', ...args, 'test'], {
      cwd: directory, encoding: 'utf8', maxBuffer: 24 * 1024 * 1024,
    });
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(directory, `${label}.log`), log);
    return {...result, log};
  }
  const correct = await run('correct');
  assert.equal(correct.status, 0, correct.log);
  // javac runs with no JUnit or JetCheck classpath: reusable source is independent.
  const sources = (await readdir(path.join(directory, sourceDir), {recursive: true}))
    .filter(name => name.endsWith('.java')).map(name => path.join(directory, sourceDir, name));
  const classes = path.join(directory, 'native-only');
  await mkdir(classes, {recursive: true});
  execFileSync('javac', ['--release', '25', '-d', classes, ...sources, check], {stdio: 'pipe', encoding: 'utf8'});
  execFileSync('java', ['-cp', classes, 'JavaDefinitionsCheck', String(machineBits)], {stdio: 'inherit'});
  for (const [index, invocation] of [
    'lawspec.definitions.example.Total.size(symbols, java.util.List.of("wrong"))',
    'lawspec.definitions.example.Total.sumTree(symbols, true)',
    'lawspec.definitions.example.Total.maybeDefault(symbols, new lawspec.runtime.LawSpecRuntime.Just<>(true))',
    'lawspec.definitions.example.Total.raw(symbols, java.util.List.of(123))',
  ].entries()) {
    const invalid = path.join(directory, 'BadDefinitionCall.java');
    await writeFile(invalid, `class BadDefinitionCall { void test() { var symbols = new java.util.HashMap<String, Object>(); ${invocation}; } }`);
    const bad = spawnSync('javac', ['--release', '25', '-cp', classes, '-d', classes, invalid], {encoding: 'utf8'});
    assert.notEqual(bad.status, 0, `native type mismatch ${index} must be rejected`);
    assert.match(bad.stderr, /incompatible types|cannot be applied/);
  }
  const compactPlan = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target: 'java', machineBits, minify: true, sourceDir, testDir,
    sources: [{path: 'total.lawspec', content: source}, {path: 'other.lawspec', content: other}],
  }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
  assert.deepEqual(compactPlan.diagnostics, []);
  for (const file of compactPlan.files.filter(file => file.ownership === 'generated')) {
    await writeFile(path.join(directory, file.path), file.content);
  }
  const compactProperties = await run('compact-properties');
  assert.equal(compactProperties.status, 0, compactProperties.log);
  for (const file of result.files.filter(file => file.ownership === 'generated')) {
    await writeFile(path.join(directory, file.path), file.content);
  }
  for (const [label, from, to, test] of [
    ['sum', 'value0.stream().map(n -> java.math.BigInteger.valueOf(n)).reduce(java.math.BigInteger.ZERO, java.math.BigInteger::add)', 'java.math.BigInteger.ZERO', 'law0*'],
    ['overflow', 'java.math.BigInteger.valueOf(value0).add(java.math.BigInteger.ONE)', 'java.math.BigInteger.valueOf((byte) (value0 + 1))', 'law1*'],
    ['tree', 'actualTree(branch.left).add(actualTree(branch.right))', 'java.math.BigInteger.ZERO', 'law2*'],
  ]) {
    const mutant = adapterSource.replace(from, to);
    assert.notEqual(mutant, adapterSource);
    await writeFile(adapterPath, mutant);
    const result = await run(label, [`-Dtest=example.TotalLawSpecTest#${test}`]);
    assert.notEqual(result.status, 0, `mutant exposed: ${label}`);
    assert.match(result.log, /AssertionFailedError|PropertyFalsified/);
    assert.doesNotMatch(result.log, /COMPILATION ERROR/);
  }
  await writeFile(adapterPath, adapterSource);
  const fixture = process.env.LAWSPEC_JAVA_DEFINITIONS_FIXTURE;
  assert.ok(fixture, 'Set LAWSPEC_JAVA_DEFINITIONS_FIXTURE');
  const sourcePath = path.join(directory, 'total.lawspec');
  const otherPath = path.join(directory, 'other.lawspec');
  await writeFile(sourcePath, source);
  await writeFile(otherPath, other);
  execFileSync(fixture, [String(machineBits), directory, sourceDir, sourcePath, otherPath]);
  assert.ok((await readFile(generated[0].destination, 'utf8')).length < generated[0].content.length);
  const compact = await run('compact');
  assert.equal(compact.status, 0, compact.log);
  for (const file of generated) await writeFile(file.destination, file.content);
  const regeneration = await mkdtemp(path.join(directory, 'regeneration-'));
  await applyWrites([await planWrites(regeneration, result.files)]);
  const adapter = result.files.find(file => file.path.endsWith('/example/Total.java') && file.ownership === 'user');
  await writeFile(path.join(regeneration, adapter.path), adapterSource);
  assert.equal((await planWrites(regeneration, result.files)).changes.length, 0);
  await writeFile(path.join(regeneration, generated[0].file.path), '// edited generated definition\n');
  await assert.rejects(planWrites(regeneration, result.files), /edited generated file/);
  console.log(`Java total definitions, native calls, properties, compact source, ownership and mutants passed: ${machineBits}`);
}
