import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const python = process.env.LAWSPEC_PYTHON ?? 'python3.13';
assert.ok(compiler, 'Set LAWSPEC_CORE');
const content = await readFile(path.join(root, 'examples/specs/collections.lawspec'), 'utf8');
const bodies = {
  reverse: 'list(reversed(value0))',
  sort: 'builtins.sorted(value0)',
  sorted: 'value0 == builtins.sorted(value0)',
  permutation: 'builtins.sorted(value0) == builtins.sorted(value1)',
  echoMaybe: 'value0', echoEither: 'value0', echoNested: 'value0',
};
for (const unit of ['lawspec_schema.shadow', 'lawspec_data_strategies.shadow']) {
  const rejected = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target: 'python', sources: [{path: 'shadow.lawspec',
      content: `unit ${unit}\nidentity :: Maybe Bool -> Maybe Bool`,
    }],
  }), encoding: 'utf8'}));
  assert.ok(rejected.diagnostics.some(diagnostic => diagnostic.code === 'collision'));
  assert.ok(!rejected.files?.length, 'reject colliding module without partial output');
}
for (const machineBits of [32, 64]) {
  const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target: 'python', machineBits,
    sources: [{path: 'collections.lawspec', content}],
  }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
  assert.deepEqual(result.diagnostics, []);
  const directory = path.join(root, `.artifacts/python-native-structures/${machineBits}`);
  let adapterPath;
  let adapterSource;
  for (const file of result.files) {
    const destination = path.join(directory, file.path);
    await mkdir(path.dirname(destination), {recursive: true});
    let source = file.content;
    if (file.ownership === 'user') {
      assert.ok(source.includes('_schema.Maybe'), 'typed native Maybe adapter');
      assert.ok(source.includes('_schema.Either'), 'typed native Either adapter');
      source = 'import builtins\n' + source;
      for (const [name, expression] of Object.entries(bodies)) {
        source = source.replace(`raise NotImplementedError("${name}")`, `return ${expression}`);
      }
      assert.ok(!source.includes('NotImplementedError'));
      adapterPath = destination;
      adapterSource = source;
    }
    await writeFile(destination, source);
  }
  const env = {...process.env, PYTHONDONTWRITEBYTECODE: '1',
    PYTHONPATH: [path.join(directory, 'src'), path.join(directory, 'tests'),
      process.env.LAWSPEC_PYTHON_DEPS ?? path.join(root, '.artifacts/python-data-deps'),
      process.env.PYTHONPATH ?? ''].filter(Boolean).join(path.delimiter),
  };
  async function run(label) {
    const result = spawnSync(python, ['-m', 'pytest', '-q', '--tb=short', 'tests'], {
      cwd: directory, env, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
    });
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(directory, `${label}.log`), log);
    return {...result, log};
  }
  const correct = await run('correct');
  assert.equal(correct.status, 0, correct.log);
  for (const [method, replacement] of [
    ['reverse', '[]'], ['sort', '[0] * len(value0)'],
    ['echoMaybe', '_schema.Nothing()'],
    ['echoEither', '_schema.Right(_schema.Nothing())'],
  ]) {
    const mutant = adapterSource.replace(new RegExp(`(def ${method}\\([\\s\\S]*?\\n    return )[^\\n]+`), `$1${replacement}`);
    assert.notEqual(mutant, adapterSource);
    await writeFile(adapterPath, mutant);
    const result = await run(method);
    assert.notEqual(result.status, 0, `mutant exposed: ${method}`);
    assert.match(result.log, /AssertionError/);
    assert.doesNotMatch(result.log, /SyntaxError|ImportError|NameError|ERROR collecting/);
  }
  await writeFile(adapterPath, adapterSource);
  console.log(`Python native List/Maybe/Either, examples, refinements and mutants passed: ${machineBits}`);
}
