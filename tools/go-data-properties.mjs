import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
assert.ok(compiler, 'Set LAWSPEC_CORE');
const rapid = process.env.LAWSPEC_RAPID ?? path.join(
  execFileSync('go', ['env', 'GOMODCACHE'], {encoding: 'utf8'}).trim(),
  'pgregory.net/rapid@v1.2.0');
const env = {...process.env, GOCACHE: path.join(root, '.artifacts/go-cache'),
  GOTOOLCHAIN: 'local', GOPROXY: 'off'};
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
const catalog = await readFile(path.join(root, 'examples/specs/scalar_catalog.lawspec'), 'utf8');
const matching = await readFile(path.join(root, 'examples/specs/matching.lawspec'), 'utf8');
const collections = await readFile(path.join(root, 'examples/specs/collections.lawspec'), 'utf8');
const finite = await readFile(path.join(root, 'examples/specs/finite_data.lawspec'), 'utf8');
for (const scenario of ['data', 'collections']) {
  for (const machineBits of [32, 64]) {
    const sourceDir = machineBits === 32 ? 'library/native' : '';
    const sources = [{path: 'main.lawspec', content: scenario === 'data' ? source : collections}];
    if (scenario === 'collections') sources.push({path: 'catalog.lawspec', content: catalog});
    if (scenario === 'data') sources.push({path: 'matching.lawspec', content: matching});
    if (scenario === 'data' && machineBits === 32) sources.push({path: 'finite.lawspec', content: finite});
    sources.push({path: 'sum_refinements.lawspec', content:
      await readFile(path.join(root, 'examples/specs/sum_refinements.lawspec'), 'utf8')});
    sources.push({path: 'list_refinements.lawspec', content:
      await readFile(path.join(root, 'examples/specs/list_refinements.lawspec'), 'utf8')});
    const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
      method: 'planGeneration', minify: process.env.LAWSPEC_MINIFY === '1', target: 'go', machineBits, sourceDir, testDir: sourceDir, sources,
    }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
    assert.deepEqual(result.diagnostics, []);
    const directory = path.join(root, `.artifacts/go-data-properties${process.env.LAWSPEC_MINIFY === '1' ? '-compact' : ''}/${scenario}/${machineBits}`);
    let adapterPath;
    let adapterSource;
    for (const file of result.files) {
      if (sourceDir) assert.ok(file.path.startsWith(`${sourceDir}/`));
      const destination = path.join(directory, file.path);
      await mkdir(path.dirname(destination), {recursive: true});
      let content = file.content;
      if (file.ownership === 'user') {
        if (scenario === 'collections' && content.includes('func Reverse(')) {
          content = content.replace(/(package \w+\n)/, '$1\nimport "slices"\n');
          const bodies = {
            reverse: 'result := slices.Clone(value0); slices.Reverse(result); return result',
            sort: 'result := slices.Clone(value0); slices.Sort(result); return result',
            sorted: 'return slices.IsSorted(value0)',
            permutation: 'a, b := slices.Clone(value0), slices.Clone(value1); slices.Sort(a); slices.Sort(b); return slices.Equal(a, b)',
          };
          for (const [name, body] of Object.entries(bodies)) {
            content = content.replace(`panic("${name}")`, body);
          }
        }
        content = content.replace('panic("getMaybe")', `return value0.(${machineBits === 32 ? 'ExampleDataTypesTypePairPair' : 'PairPair'}[LawSpecMaybe[int8], bool]).First`);
        content = content.replace(/panic\("[^"\n]+"\)/g, 'return value0');
        if (content.includes('EchoTree') || content.includes('EchoEither')) {
          adapterPath = destination;
          adapterSource = content;
        }
      }
      await writeFile(destination, content);
    }
    await writeFile(path.join(directory, 'go.mod'),
      'module properties\n\ngo 1.24.0\n\nrequire pgregory.net/rapid v1.2.0\n' +
      `replace pgregory.net/rapid => ${JSON.stringify(rapid)}\n`);
    async function run(label, selection = '.') {
      const result = spawnSync('go', ['test', './...', '-run', selection,
        '-rapid.seed=424242', '-rapid.nofailfile'], {
        cwd: directory, env, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
      });
      const log = (result.stdout ?? '') + (result.stderr ?? '');
      await writeFile(path.join(directory, `${label}.log`), log);
      return {...result, log};
    }
    const correct = await run('correct');
    assert.equal(correct.status, 0, correct.log);
    const pair = machineBits === 32 ? 'ExampleDataTypesTypePairPair' : 'PairPair';
    const mutants = scenario === 'data' ? [
      ['EchoTree', 'TreeBranch[int8]{}', 'TestLaw2'],
      ['EchoPair', `${pair}[int8, bool]{First: value0.(${pair}[int8, bool]).First, Second: false}`, 'TestLaw3'],
      ['EchoNested', 'nil', 'TestLaw4'],
      ['EchoRaw', `${pair}[uint16, []byte]{First: 0, Second: value0.(${pair}[uint16, []byte]).Second}`, 'TestLaw5'],
    ] : [
      ['Reverse', 'nil', 'TestLaw0'],
      ['Sort', 'make([]int32, len(value0))', 'TestLaw4'],
      ['EchoMaybe', 'LawSpecNothing[LawSpecMaybe[bool]]()', 'TestLaw6'],
      ['EchoEither', 'LawSpecRight[[]int32, LawSpecMaybe[bool]](LawSpecNothing[bool]())', 'TestLaw7'],
    ];
    for (const [name, replacement, selection] of mutants) {
      const mutant = adapterSource.replace(
        new RegExp(`(^func ${name}\\b[^\\{]*\\{)[\\s\\S]*?^\\}`, 'm'),
        `$1\n\treturn ${replacement}\n}`);
      assert.notEqual(mutant, adapterSource, `mutation applied: ${name}`);
      await writeFile(adapterPath, mutant);
      const result = await run(name, scenario === 'data' ? '.' : selection);
      assert.notEqual(result.status, 0, `mutant exposed: ${name}`);
      assert.match(result.log, /expect/);
      assert.doesNotMatch(result.log, /build failed|undefined:|syntax error|no test files/);
    }
    await writeFile(adapterPath, adapterSource);
    console.log(`Go ${scenario} native adapters and mutants passed: ${machineBits}`);
  }
}

for (const declaration of ['type Echo is Tag end\necho :: Echo -> Echo',
  'lawSpecJust :: Int8 -> Int8']) {
  const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target: 'go', sources: [{path: 'collision.lawspec',
      content: `unit collision\n${declaration}\n`}],
  }), encoding: 'utf8'}));
  assert.ok(result.diagnostics.some(item => item.code === 'collision' ||
    item.message.includes('collide')));
  assert.equal((result.files ?? []).length, 0);
}
