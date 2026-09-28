import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, mkdtemp, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {planWrites, applyWrites} from '../npm/files.mjs';

const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const fixture = process.env.LAWSPEC_PYTHON_DEFINITIONS_FIXTURE;
const python = process.env.LAWSPEC_PYTHON ?? 'python3.13';
assert.ok(compiler && fixture, 'Set LAWSPEC_CORE and LAWSPEC_PYTHON_DEFINITIONS_FIXTURE');
const source = await readFile(path.join(root, 'test/fixtures/total_definitions.lawspec'), 'utf8');
const other = `unit other
type Pair (a :: Type) (b :: Type) is Pair first :: a second :: b end
definition genericIdentity (x :: a) :: a is x end
definition genericCount (xs :: List a) :: BigInt is match xs with | Nil -> 0 | Cons head tail -> 1 + genericCount tail end end
law \`generic booleans\` is definition is \`for all\` (xs :: List Bool) . genericCount xs = prelude.length xs end end
law \`generic texts\` is definition is \`for all\` (xs :: List Text where genericCount xs > 0) . genericCount xs = prelude.length xs end end
definition size (x :: Bool) :: Bool is genericIdentity x end
definition str (x :: Int8) :: Int8 is x end
definition pairCount (xs :: List (Pair Int8 Bool)) :: BigInt is genericCount xs end
law \`count products\` is
  definition is \`for all\` (xs :: List (Pair Int8 Bool)) . pairCount xs = prelude.length xs end
end
`;
for (const machineBits of [32, 64]) {
  const sourceDir = machineBits === 32 ? 'library/native' : 'src';
  const testDir = machineBits === 32 ? 'checks/generated' : 'tests';
  const sources = [{path: 'total.lawspec', content: source}, {path: 'other.lawspec', content: other}];
  const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target: 'python', machineBits, sourceDir, testDir, sources,
  }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
  assert.deepEqual(result.diagnostics, []);
  const directory = path.join(root, `.artifacts/python-definitions/${machineBits}`);
  const generated = [];
  let adapter;
  let adapterSource;
  for (const file of result.files) {
    assert.ok(file.path.startsWith(`${file.placement === 'test' ? testDir : sourceDir}/`));
    const destination = path.join(directory, file.path);
    await mkdir(path.dirname(destination), {recursive: true});
    let content = file.content;
    if (file.path.endsWith('/example/total.py') && file.ownership === 'user') {
      assert.doesNotMatch(content, /def (size|sumList|sumTree|increment)\(/);
      content = content.replace('raise NotImplementedError("actualSum")', 'return sum(value0)')
        .replace('raise NotImplementedError("actualIncrement")', 'return value0 + 1')
        .replace('raise NotImplementedError("actualTree")',
          'return value0.value if isinstance(value0, data.TreeLeaf) else actualTree(value0.left) + actualTree(value0.right)');
      adapter = file;
      adapterSource = content;
    }
    if (file.path.includes('/lawspec_definitions/') || file.path.endsWith('/lawspec_definition_bodies.py')) {
      assert.equal(file.ownership, 'generated');
      assert.equal(file.placement, 'source');
      for (const [index, line] of content.split('\n').entries()) {
        assert.ok(line.length <= 79, `${file.path}:${index + 1}: line exceeds 79 columns`);
        assert.doesNotMatch(line, /[ \t]+$/);
      }
      generated.push({file, destination, content});
    }
    await writeFile(destination, content);
  }
  assert.equal(generated.length, 3);
  const env = {...process.env, PYTHONDONTWRITEBYTECODE: '1',
    PYTHONPATH: [path.join(directory, sourceDir), path.join(directory, testDir),
      process.env.LAWSPEC_PYTHON_DEPS ?? path.join(root, '.artifacts/python-data-deps')].join(path.delimiter),
  };
  const nativeEnv = {...env, PYTHONPATH: path.join(directory, sourceDir)};
  execFileSync(python, ['-S', path.join(root, 'test/runtime/PythonDefinitionsCheck.py'), String(machineBits)],
    {env: nativeEnv, stdio: 'inherit'});
  async function run(label) {
    const result = spawnSync(python, ['-m', 'pytest', '-q', '--tb=short', testDir], {
      cwd: directory, env, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
    });
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(directory, `${label}.log`), log);
    return {...result, log};
  }
  const correct = await run('correct');
  assert.equal(correct.status, 0, correct.log);
  for (const [label, from, to] of [
    ['sum', 'return sum(value0)', 'return 0'],
    ['overflow', 'return value0 + 1', 'return (value0 + 129) % 256 - 128'],
    ['tree', 'actualTree(value0.left) + actualTree(value0.right)', '0'],
  ]) {
    const mutation = adapterSource.replace(from, to);
    assert.notEqual(mutation, adapterSource);
    await writeFile(path.join(directory, adapter.path), mutation);
    const result = await run(label);
    assert.notEqual(result.status, 0, `mutant exposed: ${label}`);
    assert.match(result.log, /AssertionError/);
    assert.doesNotMatch(result.log, /SyntaxError|ImportError|NameError|ERROR collecting/);
  }
  await writeFile(path.join(directory, adapter.path), adapterSource);
  const sourcePaths = [];
  for (const item of sources) {
    const file = path.join(directory, item.path);
    await writeFile(file, item.content);
    sourcePaths.push(file);
  }
  execFileSync(fixture, [String(machineBits), directory, sourceDir, ...sourcePaths]);
  assert.ok((await readFile(generated[0].destination, 'utf8')).length < generated[0].content.length);
  execFileSync(python, ['-S', path.join(root, 'test/runtime/PythonDefinitionsCheck.py'), String(machineBits)],
    {env: nativeEnv, stdio: 'inherit'});
  const compact = await run('compact');
  assert.equal(compact.status, 0, compact.log);
  for (const item of generated) await writeFile(item.destination, item.content);
  const regeneration = await mkdtemp(path.join(directory, 'regeneration-'));
  await applyWrites([await planWrites(regeneration, result.files)]);
  await writeFile(path.join(regeneration, adapter.path), adapterSource);
  assert.equal((await planWrites(regeneration, result.files)).changes.length, 0);
  await writeFile(path.join(regeneration, generated[0].file.path), '# edited generated definition\n');
  await assert.rejects(planWrites(regeneration, result.files), /edited generated file/);
  console.log(`Python definitions, native calls, properties, compact source, ownership and mutants passed: ${machineBits}`);
}
