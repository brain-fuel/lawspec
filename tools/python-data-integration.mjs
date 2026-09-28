import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const python = process.env.LAWSPEC_PYTHON ?? 'python3.13';
assert.ok(compiler, 'Set LAWSPEC_CORE');
const source = await readFile(path.join(root, 'examples/specs/data_types.lawspec'), 'utf8') + `
echoTree :: Tree Int8 -> Tree Int8
echoPair :: Pair Int8 Bool -> Pair Int8 Bool
echoNested :: List (Maybe (Tree Int8)) -> List (Maybe (Tree Int8))
echoRaw :: Pair CodeUnit16 Bytes -> Pair CodeUnit16 Bytes
getMaybe :: Pair (Maybe Int8) Bool -> Maybe Int8
law \`native tree\` is definition is \`for all\` (x :: Tree Int8) . echoTree x = x end end
law \`native product\` is definition is \`for all\` (x :: Pair Int8 Bool) . echoPair x = x end end
law \`native nested containers\` is definition is \`for all\` (x :: List (Maybe (Tree Int8))) . echoNested x = x end end
law \`native raw values\` is definition is \`for all\` (x :: Pair CodeUnit16 Bytes) . echoRaw x = x end end
law \`native fields compose\` is definition is \`for all\` (x :: Pair (Maybe Int8) Bool) . getMaybe x = (match x with | Pair first second -> first end) end end
`;
const finiteSource = await readFile(path.join(root, 'examples/specs/finite_data.lawspec'), 'utf8');
for (const machineBits of [32, 64]) {
  const sourceDir = machineBits === 32 ? 'library/native' : 'src';
  const testDir = machineBits === 32 ? 'checks/properties' : 'tests';
  const sources = [{path: 'data.lawspec', content: source}];
  if (machineBits === 32) sources.push({path: 'finite.lawspec', content: finiteSource});
  sources.push({path: 'sum_refinements.lawspec', content:
    await readFile(path.join(root, 'examples/specs/sum_refinements.lawspec'), 'utf8')});
  sources.push({path: 'list_refinements.lawspec', content:
    await readFile(path.join(root, 'examples/specs/list_refinements.lawspec'), 'utf8')});
  const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', minify: process.env.LAWSPEC_MINIFY === '1', target: 'python', machineBits, sourceDir, testDir, sources,
  }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
  assert.deepEqual(result.diagnostics, []);
  const directory = path.join(root, `.artifacts/python-data-properties${process.env.LAWSPEC_MINIFY === '1' ? '-compact' : ''}/${machineBits}`);
  let adapterPath;
  let adapterSource;
  const pairVariant = machineBits === 32 ? 'ExampleDataTypesTypePairPair' : 'PairPair';
  for (const file of result.files) {
    assert.ok(file.path.startsWith(`${file.placement === 'test' ? testDir : sourceDir}/`));
    const destination = path.join(directory, file.path);
    await mkdir(path.dirname(destination), {recursive: true});
    let content = file.content;
    if (file.ownership === 'user') {
      content = content.replace('raise NotImplementedError("getMaybe")', 'return value0.first');
      content = content.replace(/raise NotImplementedError\("[^"\n]+"\)/g, 'return value0');
      if (content.includes('echoTree')) {
        adapterPath = destination;
        adapterSource = content;
      }
    }
    await writeFile(destination, content);
  }
  await writeFile(path.join(directory, testDir, 'test_data_strategies.py'),
    await readFile(path.join(root, 'test/runtime/PythonDataStrategiesCheck.py'), 'utf8'));
  await writeFile(path.join(directory, testDir, 'test_constructor_contracts.py'),
    await readFile(path.join(root, 'test/runtime/PythonConstructorContractsCheck.py'), 'utf8'));
  const env = {...process.env, PYTHONDONTWRITEBYTECODE: '1',
    PYTHONPATH: [path.join(directory, sourceDir), path.join(directory, testDir),
      process.env.LAWSPEC_PYTHON_DEPS ?? path.join(root, '.artifacts/python-data-deps'),
      process.env.PYTHONPATH ?? ''].filter(Boolean).join(path.delimiter),
  };
  function run(label, selector = testDir) {
    const result = spawnSync(python, ['-m', 'pytest', '-q', '--tb=short', ...(label === 'correct' ? [] : ['-x']), selector], {
      cwd: directory, env, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
    });
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    return writeFile(path.join(directory, `${label}.log`), log).then(() => ({...result, log}));
  }
  const correct = await run('correct');
  assert.equal(correct.status, 0, correct.log);
  for (const [method, replacement] of [
    ['echoTree', 'data.TreeBranch([])'],
    ['echoPair', `data.${pairVariant}(value0.first, False)`],
    ['echoNested', '[]'],
    ['echoRaw', `data.${pairVariant}(0, value0.second)`],
  ]) {
    const mutant = adapterSource.replace(new RegExp(`(def ${method}\\([\\s\\S]*?\\n    )return value0`), `$1return ${replacement}`);
    assert.notEqual(mutant, adapterSource, `mutation applied: ${method}`);
    await writeFile(adapterPath, mutant);
    const result = await run(method, `${testDir}/test_example_data_types_lawspec.py`);
    assert.notEqual(result.status, 0, `mutant exposed: ${method}`);
    assert.match(result.log, /AssertionError/, result.log);
    assert.doesNotMatch(result.log, /SyntaxError|ImportError|NameError|not found:|ERROR collecting/);
  }
  await writeFile(adapterPath, adapterSource);
  console.log(`Python native custom data, checked adapters, properties and mutants passed: ${machineBits}`);
}
