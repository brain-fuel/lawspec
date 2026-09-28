import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {templates} from '../npm/templates.mjs';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
assert.ok(compiler, 'Set LAWSPEC_CORE');
const source = await readFile(path.join(root, 'examples/specs/data_types.lawspec'), 'utf8') + `
type Box (a :: Type) is Boxed fields :: a tag :: Text end
type Envelope (a :: Type) is Pack payload :: a end
type MutualA is StopA | ToB next :: MutualB end
type MutualB is ToA next :: Maybe MutualA end
type Indirect (a :: Type) is Done | Into wrapped :: Envelope (Indirect a) end
type Chain is End | Link value :: Int8 tail :: Chain end
type Phantom (a :: Type) is Token end
type Empty (a :: Type) is end
type Nested (a :: Type) is Stop | Next child :: Maybe (Nested a) end
echoTree :: Tree Int8 -> Tree Int8
echoPair :: Pair Int8 Bool -> Pair Int8 Bool
echoNested :: List (Maybe (Tree Int8)) -> List (Maybe (Tree Int8))
echoChain :: Chain -> Chain
echoRaw :: Pair CodeUnit16 Bytes -> Pair CodeUnit16 Bytes
echoMutual :: MutualA -> MutualA
law \`native tree\` is definition is \`for all\` (x :: Tree Int8) . echoTree x = x end end
law \`native product\` is definition is \`for all\` (x :: Pair Int8 Bool) . echoPair x = x end end
law \`native nested containers\` is definition is \`for all\` (x :: List (Maybe (Tree Int8))) . echoNested x = x end end
law \`native recursion\` is definition is \`for all\` (x :: Chain) . echoChain x = x end end
law \`native raw data\` is definition is \`for all\` (x :: Pair CodeUnit16 Bytes) . echoRaw x = x end end
law \`native mutual recursion\` is definition is \`for all\` (x :: MutualA) . echoMutual x = x end end
`;
const finiteSource = await readFile(path.join(root, 'examples/specs/finite_data.lawspec'), 'utf8');
const nativeBits = Number(execFileSync('rustc', ['--print', 'cfg'], {encoding: 'utf8'})
  .match(/target_pointer_width="(32|64)"/)[1]);
for (const machineBits of [32, 64]) {
  const sourceDir = machineBits === 32 ? 'library/native' : 'src';
  const testDir = machineBits === 32 ? 'checks/properties' : 'tests';
  const sources = [{path: 'data.lawspec', content: source}];
  if (machineBits === 32) sources.push({path: 'finite.lawspec', content: finiteSource});
  sources.push({path: 'machine.lawspec', content: `unit example.machine_data
type Machine is Machine size :: IntSize end
echo :: Machine -> Machine
law \`native architecture\` is definition is \`for all\` (x :: Machine) . echo x = x end end`});
  const pairName = machineBits === 32 ? 'ExampleDataTypesTypePair' : 'Pair';
  sources.push({path: 'sum_refinements.lawspec', content:
    await readFile(path.join(root, 'examples/specs/sum_refinements.lawspec'), 'utf8')});
  sources.push({path: 'list_refinements.lawspec', content:
    await readFile(path.join(root, 'examples/specs/list_refinements.lawspec'), 'utf8')});
  const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', minify: process.env.LAWSPEC_MINIFY === '1', target: 'rust', machineBits, sourceDir, testDir,
    sources,
  }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
  assert.deepEqual(result.diagnostics, []);
  const directory = path.join(root, `.artifacts/rust-native-data${process.env.LAWSPEC_MINIFY === '1' ? '-compact' : ''}/${machineBits}`);
  await mkdir(path.join(directory, sourceDir), {recursive: true});
  const scaffold = templates('rust');
  const tests = result.files.filter(f => f.path.endsWith('_lawspec.rs'));
  const manifest = scaffold['Cargo.toml'] + `\n[lib]\npath="${sourceDir}/lib.rs"\n` +
    tests.map((file, i) => `\n[[test]]\nname="laws_${i}"\npath="${file.path}"\n`).join('');
  await writeFile(path.join(directory, 'Cargo.toml'), manifest);
  await writeFile(path.join(directory, sourceDir, 'lib.rs'), scaffold['src/lib.rs']);
  let adapterPath;
  let adapterSource;
  for (const file of result.files) {
    assert.ok(file.path.startsWith(`${file.placement === 'test' ? testDir : sourceDir}/`));
    const destination = path.join(directory, file.path);
    await mkdir(path.dirname(destination), {recursive: true});
    let content = file.content;
    if (file.ownership === 'user') {
      content = content.replace(/todo!\("[^"\n]+"\)/g, 'value0');
      if (content.includes('echoTree')) {
        adapterPath = destination;
        adapterSource = content;
      }
    }
    if (file.path.endsWith('/example_data_types_lawspec.rs')) {
      content += await readFile(path.join(root, 'test/runtime/RustDataCheck.rs'), 'utf8');
    }
    await writeFile(destination, content);
    if (process.env.LAWSPEC_MINIFY !== '1' && ['lawspec_data.rs', 'lawspec_schema.rs', 'lawspec_runtime.rs', 'lawspec_strategies.rs'].some(name => file.path.endsWith(`/${name}`))) {
      assert.equal(content, execFileSync('rustfmt', ['--edition', '2024'], {input: content, encoding: 'utf8'}), `Generated support matches rustfmt: ${file.path}`);
    }
  }
  function run(label, filter = []) {
    const result = spawnSync('cargo', ['test', '--offline', '--quiet', ...filter], {
      cwd: directory, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
      env: {...process.env, CARGO_TARGET_DIR: path.join(root, `.artifacts/rust-native-data${process.env.LAWSPEC_MINIFY === '1' ? '-compact' : ''}/target`)},
    });
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    return writeFile(path.join(directory, `${label}.log`), log).then(() => ({...result, log}));
  }
  const machineIndex = tests.findIndex(file => file.path.endsWith('/example_machine_data_lawspec.rs'));
  assert.ok(machineIndex >= 0);
  const correct = await run('correct', ['--lib', ...tests.flatMap((_, i) => i === machineIndex ? [] : ['--test', `laws_${i}`])]);
  assert.equal(correct.status, 0, correct.log);
  const architecture = await run('architecture', ['--test', `laws_${machineIndex}`]);
  if (machineBits === nativeBits) assert.equal(architecture.status, 0, architecture.log);
  else {
    assert.notEqual(architecture.status, 0);
    assert.match(architecture.log, /machineBits does not match native architecture/);
    assert.doesNotMatch(architecture.log, /error\[E\d+\]/);
  }
  const dataIndex = tests.findIndex(file => file.path.endsWith('/example_data_types_lawspec.rs'));
  assert.ok(dataIndex >= 0);
  for (const [method, replacement] of [
    ['echoTree', 'crate::lawspec_data::Tree::Branch { children: vec![] }'],
    ['echoPair', `match value0 { crate::lawspec_data::${pairName}::Pair { first, .. } => crate::lawspec_data::${pairName}::Pair { first, second: false } }`],
    ['echoNested', 'vec![]'],
    ['echoChain', 'crate::lawspec_data::Chain::End'],
    ['echoMutual', 'crate::lawspec_data::MutualA::StopA'],
  ]) {
    const mutant = adapterSource.replace(new RegExp(`(pub fn ${method}\\([\\s\\S]*?\\{)\\s*value0`), `$1 ${replacement}`);
    assert.notEqual(mutant, adapterSource, `mutation applied: ${method}`);
    await writeFile(adapterPath, mutant);
    const result = await run(method, ['--test', `laws_${dataIndex}`]);
    assert.notEqual(result.status, 0, `mutant exposed: ${method}`);
    assert.match(result.log, /test result: FAILED/, result.log);
    assert.doesNotMatch(result.log, /error\[E\d+\]/);
  }
  await writeFile(adapterPath, adapterSource);
  console.log(`Rust native custom data, checked bridges, recursive generators and mutants passed: ${machineBits}`);
}
