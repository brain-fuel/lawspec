import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {templates} from '../npm/templates.mjs';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
assert.ok(compiler, 'Set LAWSPEC_CORE');
const source = await readFile(path.join(root, 'examples/specs/data_types.lawspec'), 'utf8') + `
echoTree :: Tree Int8 -> Tree Int8
echoPair :: Pair Int8 Bool -> Pair Int8 Bool
echoNested :: List (Maybe (Tree Int8)) -> List (Maybe (Tree Int8))
law \`native tree\` is definition is \`for all\` (x :: Tree Int8) . echoTree x = x end end
law \`native product\` is definition is \`for all\` (x :: Pair Int8 Bool) . echoPair x = x end end
law \`native nested containers\` is definition is \`for all\` (x :: List (Maybe (Tree Int8))) . echoNested x = x end end
`;
const finiteSource = await readFile(path.join(root, 'examples/specs/finite_data.lawspec'), 'utf8');
for (const machineBits of [32, 64]) {
 for (const customLayout of [false, true]) {
  const sourceDir = customLayout ? 'generated/source' : 'src/main/java';
  const testDir = customLayout ? 'generated/tests' : 'src/test/java';
  const sources = [{path: 'data.lawspec', content: source}];
  if (customLayout) sources.push({path: 'finite.lawspec', content: finiteSource});
  sources.push({path: 'sum_refinements.lawspec', content:
    await readFile(path.join(root, 'examples/specs/sum_refinements.lawspec'), 'utf8')});
  sources.push({path: 'list_refinements.lawspec', content:
    await readFile(path.join(root, 'examples/specs/list_refinements.lawspec'), 'utf8')});
  const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', minify: process.env.LAWSPEC_MINIFY === '1', target: 'java', machineBits, sourceDir, testDir, sources,
  }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
  assert.deepEqual(result.diagnostics, []);
  const directory = path.join(root, `.artifacts/java-data-properties${process.env.LAWSPEC_MINIFY === '1' ? '-compact' : ''}/${machineBits}/${customLayout ? 'multi-unit-custom' : 'default'}`);
  for (const [name, content] of Object.entries(templates('java'))) {
    const destination = path.join(directory, name);
    await mkdir(path.dirname(destination), {recursive: true});
    await writeFile(destination, name === 'pom.xml' ? content.replace('<build>',
      `<build><sourceDirectory>${sourceDir}</sourceDirectory><testSourceDirectory>${testDir}</testSourceDirectory>`) : content);
  }
  assert.equal(new Set(result.files.map(file => file.path.toLowerCase())).size, result.files.length);
  for (const file of result.files) {
    assert.ok(file.path.startsWith(`${file.placement === 'test' ? testDir : sourceDir}/`),
      `artifact uses configured directory: ${file.path}`);
  }
  const pairName = customLayout ? 'ExampleDataTypesTypePair' : 'Pair';
  if (customLayout) {
    for (const name of [pairName, 'ExampleFiniteDataTypePair']) {
      assert.ok(result.files.some(file => file.path === `${sourceDir}/lawspec/data/${name}.java`));
    }
  }
  let adapterPath;
  let adapterSource;
  for (const file of result.files) {
    const destination = path.join(directory, file.path);
    await mkdir(path.dirname(destination), {recursive: true});
    let content = file.content;
    if (file.ownership === 'user') {
      content = content.replace(/throw new UnsupportedOperationException\(\s*"echo[^;]+;/g, 'return value0;');
      if (content.includes("echoTree")) {
        adapterPath = destination;
        adapterSource = content;
      }
      assert.ok(!content.includes('UnsupportedOperationException'), 'unimplemented adapter');
    }
    await writeFile(destination, content);
  }
  await writeFile(path.join(directory, `${testDir}/example/DataStrategiesTest.java`),
    await readFile(path.join(root, 'test/runtime/DataStrategiesTest.java'), 'utf8'));
  const run = spawnSync('mvn', ['-o', '-q', 'test'], {cwd: directory, encoding: 'utf8'});
  const log = (run.stdout ?? '') + (run.stderr ?? '');
  await writeFile(path.join(directory, 'test.log'), log);
  if (run.status !== 0) process.stdout.write(log);
  assert.equal(run.status, 0, `Java data properties at ${machineBits} bits`);
  for (const [method, replacement] of [
    ['echoTree', 'return new lawspec.data.Tree.BranchCase<>(java.util.List.of());'],
    ['echoPair', `return new lawspec.data.${pairName}.PairCase<>(((lawspec.data.${pairName}.PairCase<Byte, Boolean>) value0).first, false);`],
    ['echoNested', 'return java.util.List.of();'],
  ]) {
    const mutant = adapterSource.replace(new RegExp(`(${method}\\([\\s\\S]*?\\{)\\s*return value0;`), `$1 ${replacement}`);
    assert.notEqual(mutant, adapterSource, `mutation applied: ${method}`);
    await writeFile(adapterPath, mutant);
    const result = spawnSync('mvn', ['-o', '-q', '-Dtest=example.DataTypesLawSpecTest', 'test'],
      {cwd: directory, encoding: 'utf8'});
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(directory, `${method}-mutant.log`), log);
    assert.notEqual(result.status, 0, `mutant exposed: ${method}`);
    assert.ok(log.includes(method === 'echoPair' ? 'AssertionFailedError' : 'PropertyFalsified'), `property failure, not build failure: ${method}\n${log}`);
  }
  await writeFile(adapterPath, adapterSource);
  console.log(`Java custom data properties and native adapters passed: ${machineBits}, ${customLayout ? 'multi-unit custom layout' : 'default layout'}`);
 }
}
