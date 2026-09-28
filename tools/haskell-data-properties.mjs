import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const ghc = process.env.LAWSPEC_GHC;
const minify = process.env.LAWSPEC_MINIFY === '1';
assert.ok(compiler && ghc, 'Set LAWSPEC_CORE and LAWSPEC_GHC');
const packageArgs = process.env.LAWSPEC_GHC_PACKAGE_DB
  ? ['-package-db', process.env.LAWSPEC_GHC_PACKAGE_DB] : [];
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
  for (const machineBits of (process.env.LAWSPEC_MACHINE_BITS ?? (scenario === 'scalars' ? '64' : '32,64')).split(',').map(Number)) {
    const pairConstructor = machineBits === 32 ? 'ExampleDataTypesTypePairPair' : 'PairPair';
    const sourceDir = machineBits === 32 ? 'library/native' : 'src';
    const testDir = machineBits === 32 ? 'checks/generated' : 'test';
    const main = scenario === 'data' ? source :
      await readFile(path.join(root, `examples/specs/${scenario === 'scalars' ? 'scalar_adapters' : scenario === 'refinements' ? 'refinements' : 'collections'}.lawspec`), 'utf8');
    const sources = [{path: 'main.lawspec', content: main},
      {path: 'matching.lawspec', content:
        await readFile(path.join(root, 'examples/specs/matching.lawspec'), 'utf8')}];
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
      method: 'planGeneration', target: 'haskell', machineBits, minify,
      sourceDir, testDir, sources,
    }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
    assert.deepEqual(result.diagnostics, []);
    const directory = path.join(root, `.artifacts/haskell-data-properties${minify ? '-compact' : ''}/${scenario}/${machineBits}`);
    let adapterPath;
    let adapterSource;
    const specModules = [];
    for (const file of result.files) {
      assert.ok(file.path.startsWith(`${file.placement === 'test' ? testDir : sourceDir}/`));
      const destination = path.join(directory, file.path);
      await mkdir(path.dirname(destination), {recursive: true});
      let content = file.content;
      if (file.ownership === 'user') {
        content = content.replace(/^(module .* where)$/m,
          '$1\nimport qualified Data.List as List\nimport qualified Prelude as Prelude');
        content = content.replace(/^(\w+)((?: _)*) = error "[^"\n]*"$/gm,
          (_, name, args) => {
            const parameters = args.trim().split(' ').filter(Boolean).map((_, i) => `value${i}`);
            const bodies = {
              reverse: 'Prelude.reverse value0', sort: 'List.sort value0',
              sorted: 'value0 == List.sort value0',
              permutation: 'List.sort value0 == List.sort value1',
              getMaybe: `case value0 of Data.${pairConstructor} first _ -> first`,
              successor: 'toInteger value0 + 1',
              addDecimal: 'case (value0, value1) of (LS.Decimal a, LS.Decimal b) -> LS.Decimal (a + b)',
              sameSymbol: 'value0 == value1',
              add: 'toInteger value0 + toInteger value1',
              count: 'toInteger (T.length value0)', preserve: 'toInteger value0',
            };
            return `${name} ${parameters.join(' ')} = ${bodies[name] ?? 'value0'}`;
          });
        if (content.includes('echoTree ::') || content.includes('echoEither ::') || content.includes('successor ::')) {
          adapterPath = destination;
          adapterSource = content;
        }
      }
      if (file.path.endsWith('Spec.hs')) {
        specModules.push(content.match(/^module (\S+) /m)[1]);
      }
      await writeFile(destination, content);
    }
    await writeFile(path.join(directory, 'Main.hs'),
      'import Test.Hspec\n' + specModules.map((module, i) =>
        `import qualified ${module} as Spec${i}\n`).join('') +
      'main :: IO ()\nmain = hspec $ do\n' +
      specModules.map((_, i) => `  Spec${i}.spec\n`).join(''));
    async function run(label) {
      const build = spawnSync(ghc, [...packageArgs, '--make', 'Main.hs',
        `-i${sourceDir}`, `-i${testDir}`, '-O0', '-outputdir', 'build', '-o', 'check'],
        {cwd: directory, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024});
      await writeFile(path.join(directory, `${label}-build.log`), build.stdout + build.stderr);
      assert.equal(build.status, 0, build.stdout + build.stderr);
      const run = spawnSync(path.join(directory, 'check'), [],
        {cwd: directory, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024});
      await writeFile(path.join(directory, `${label}.log`), run.stdout + run.stderr);
      return run;
    }
    const correct = await run('correct');
    assert.equal(correct.status, 0, correct.stdout + correct.stderr);
    const mutations = scenario === 'data' ? [
      ['tree', 'echoTree value0 = value0', 'echoTree value0 = Data.TreeBranch []'],
      ['pair', 'echoPair value0 = value0', `echoPair value0 = Data.${pairConstructor} 0 False`],
      ['nested', 'echoNested value0 = value0', 'echoNested value0 = []'],
      ['raw', 'echoRaw value0 = value0', `echoRaw value0 = Data.${pairConstructor} 0 mempty`],
      ['contract', 'contractEcho value0 = value0', 'contractEcho value0 = Data.TreeLeaf 0'],
    ] : scenario === 'refinements' ? [
      ['overflow', 'toInteger value0 + toInteger value1', 'toInteger (value0 + value1)'],
      ['precision', 'preserve value0 = toInteger value0', 'preserve value0 = truncate (fromIntegral value0 :: Double)'],
      ['refinement', 'positive value0 = value0', 'positive value0 = 0'],
      ['standalone', 'toInteger (T.length value0)', '0'],
    ] : scenario === 'scalars' ? [
      ['promotion', 'toInteger value0 + 1', 'toInteger (value0 + 1)'],
      ['symbol', 'sameSymbol value0 value1 = value0 == value1', 'sameSymbol value0 value1 = True'],
      ['presence', 'echoPresence value0 = value0', 'echoPresence value0 = LS.UndefinedValue'],
      ['raw', 'echoRaw value0 = value0', 'echoRaw value0 = LS.Utf16Text []'],
    ] : [
      ['reverse', 'Prelude.reverse value0', '[]'],
      ['sort', 'sort value0 = List.sort value0', 'sort value0 = replicate (length value0) 0'],
      ['maybe', 'echoMaybe value0 = value0', 'echoMaybe value0 = Nothing'],
      ['either', 'echoEither value0 = value0', 'echoEither value0 = Right Nothing'],
      ['nested', 'echoNested value0 = value0', 'echoNested value0 = []'],
    ];
    for (const [name, before, after] of mutations) {
      assert.ok(adapterSource.includes(before), before);
      await writeFile(adapterPath, adapterSource.replace(before, after));
      const mutant = await run(`mutant-${name}`);
      assert.notEqual(mutant.status, 0, `mutant survived: ${name}`);
      assert.match(mutant.stdout + mutant.stderr, /expected=|expect |postcondition/);
    }
    await writeFile(adapterPath, adapterSource);
    console.log(`Haskell ${scenario} properties and ${mutations.length} mutants passed: ${machineBits}`);
  }
}
