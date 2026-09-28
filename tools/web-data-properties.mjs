import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile, symlink} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
assert.ok(compiler, 'Set LAWSPEC_CORE');
const tsc = process.env.LAWSPEC_TSC ?? path.join(
  root, '.artifacts/web-data-deps/typescript/bin/tsc');
const dependencies = path.join(root, '.artifacts/lists/javascript/node_modules');
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
const collections = await readFile(path.join(root, 'examples/specs/collections.lawspec'), 'utf8');
const finite = await readFile(path.join(root, 'examples/specs/finite_data.lawspec'), 'utf8');
for (const scenario of ['data', 'collections']) {
for (const target of ['javascript', 'typescript']) {
  const ts = target === 'typescript';
  for (const machineBits of [32, 64]) {
    const sourceDir = machineBits === 32 ? 'library/native' : 'src';
    const testDir = machineBits === 32 ? 'checks/properties' : 'test';
    const sources = [{path: 'data.lawspec', content: scenario === 'data' ? source : collections}];
    if (machineBits === 32 && scenario === 'data') sources.push({path: 'finite.lawspec', content: finite});
    sources.push({path: 'sum_refinements.lawspec', content:
      await readFile(path.join(root, 'examples/specs/sum_refinements.lawspec'), 'utf8')});
    sources.push({path: 'list_refinements.lawspec', content:
      await readFile(path.join(root, 'examples/specs/list_refinements.lawspec'), 'utf8')});
    const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
      method: 'planGeneration', minify: process.env.LAWSPEC_MINIFY === '1', target, machineBits, sourceDir, testDir, sources,
    }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
    assert.deepEqual(result.diagnostics, []);
    const directory = path.join(root, `.artifacts/web-data-properties${process.env.LAWSPEC_MINIFY === '1' ? '-compact' : ''}/${scenario}/${target}/${machineBits}`);
    let adapterPath;
    let adapterSource;
    const testPaths = [];
    const pair = machineBits === 32 ? 'ExampleDataTypesTypePairPair' : 'PairPair';
    for (const file of result.files) {
      assert.ok(file.path.startsWith(`${file.placement === 'test' ? testDir : sourceDir}/`));
      const destination = path.join(directory, file.path);
      await mkdir(path.dirname(destination), {recursive: true});
      let content = file.content;
      if (file.ownership === 'user') {
        content = content.replace(/throw new Error\((["'])reverse\1\);/, 'return [...value0].reverse();');
        content = content.replace(/throw new Error\((["'])sort\1\);/, 'return [...value0].sort((a, b) => a - b);');
        content = content.replace(/throw new Error\((["'])sorted\1\);/, 'return value0.every((value, index) => index === 0 || value0[index - 1] <= value);');
        content = content.replace(/throw new Error\((["'])permutation\1\);/, 'return value0.length === value1.length && [...value0].sort((a, b) => a - b).every((value, index) => value === [...value1].sort((a, b) => a - b)[index]);');
        content = content.replace(/throw new Error\((["'])getMaybe\1\);/, 'return value0.first;');
        content = content.replace(/throw new Error\((['"])[^'"\n]+\1\);/g, 'return value0;');
        if (content.includes('echoTree') || content.includes('echoEither')) {
          adapterPath = destination;
          adapterSource = content;
        }
      }
      if (file.path.includes('.lawspec.test.')) {
        testPaths.push(path.join(ts ? 'dist' : '', file.path.replace(/\.ts$/, '.js')));
      }
      await writeFile(destination, content);
    }
    await writeFile(path.join(directory, 'package.json'), '{"type":"module"}\n');
    await symlink(dependencies, path.join(directory, 'node_modules')).catch(error => {
      if (error.code !== 'EEXIST') throw error;
    });
    if (ts) {
      await writeFile(path.join(directory, 'tsconfig.json'), JSON.stringify({
        compilerOptions: {target: 'ES2022', module: 'NodeNext', strict: true,
          rootDir: '.', outDir: 'dist', skipLibCheck: true},
        include: [`${sourceDir}/**/*.ts`, `${testDir}/**/*.ts`],
      }));
    }
    async function run(label, pattern) {
      if (ts) execFileSync(process.execPath, [tsc, '-p', directory], {stdio: 'inherit'});
      const result = spawnSync(process.execPath, ['--test',
        ...(pattern ? ['--test-name-pattern', pattern] : []), ...testPaths], {
        cwd: directory, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
      });
      const log = (result.stdout ?? '') + (result.stderr ?? '');
      await writeFile(path.join(directory, `${label}.log`), log);
      return {...result, log};
    }
    const correct = await run('correct');
    assert.equal(correct.status, 0, correct.log);
    for (const [method, replacement, law] of (scenario === 'data' ? [
      ['echoTree', 'new data.TreeBranch([])', 'native tree'],
      ['echoPair', `new data.${pair}(value0.first, false)`, 'native product'],
      ['echoNested', '[]', 'native nested containers'],
      ['echoRaw', `new data.${pair}(0, value0.second)`, 'native raw values'],
    ] : [
      ['reverse', '[]', 'reverse twice restores'],
      ['sort', 'value0.map(() => 0)', 'sort preserves elements'],
      ['echoMaybe', 'new data.Nothing()', 'Maybe preserves nested absence'],
      ['echoEither', 'new data.Right(new data.Nothing())', 'Either preserves branches'],
    ])) {
      const mutant = adapterSource.replace(
        new RegExp(`(function ${method}\\b[^\\{]*\\{\\s*)return [^;]+;`),
        `$1return ${replacement};`);
      assert.notEqual(mutant, adapterSource, `mutation applied: ${method}`);
      await writeFile(adapterPath, mutant);
      const result = await run(method, law);
      assert.notEqual(result.status, 0, `mutant exposed: ${method}`);
      assert.match(result.log, /expect|Property failed/);
      assert.doesNotMatch(result.log, /SyntaxError|ReferenceError|ERR_MODULE_NOT_FOUND/);
    }
    await writeFile(adapterPath, adapterSource);
    console.log(`${target} ${scenario} native adapters, properties and mutants passed: ${machineBits}`);
  }
}
}
