// Execute generated Python bridges against application-owned payment classes.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';

const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const python = process.env.LAWSPEC_PYTHON ?? 'python3.13';
assert.ok(compiler, 'Set LAWSPEC_CORE');
const wasm = await createCompiler();
const fixture = path.join(root, 'test/fixtures/native-payments');
const source = await readFile(path.join(root, 'examples/specs/payments.lawspec'), 'utf8');
const nativeBindings = JSON.parse(await readFile(path.join(fixture, 'bindings-python.json')));
const scaffold = process.env.LAWSPEC_GENERATOR_STUBS === '1';
if (scaffold || process.env.LAWSPEC_NATIVE_GENERATORS === '1') nativeBindings.generators = [{
  type:'example.payments::type::Money', factory:['lawspec_generators','prices'],
}, {type:'Int8', factory:['lawspec_generators','small_integers']},
{type:'Unit', factory:['lawspec_generators','units']}];
if (scaffold) {
  nativeBindings.generators.push({type:'List',factory:['lawspec_generators','lists']});
  for (const generator of nativeBindings.generators) generator.stub = true;
}
const sources = [{path:'payments.lawspec',content:source}];
if (nativeBindings.generators) sources.push({path:'generators.lawspec',content:`
unit native.generator_checks
law \`refined input uses its factory\` is
  definition is \`for all\` (x :: Int8 where x > 5) . x = x end
end
law \`finite Unit uses exhaustive cases\` is
  definition is \`for all\` (x :: Unit) . x = x end
end
`});
const domain = await readFile(path.join(fixture, 'domain.py'), 'utf8');
for (const minify of [false, true]) for (const machineBits of [32, 64]) {
  const sourceDir = machineBits === 32 ? 'library/native' : 'src';
  const testDir = machineBits === 32 ? 'checks/properties' : 'tests';
  const output = path.join(root, '.artifacts/python-native-payments',
    `${machineBits}-${minify}${nativeBindings.generators ? '-generators' : ''}${scaffold ? '-stubs' : ''}`);
  const request = {schemaVersion:4, method:'planGeneration', target:'python', minify,
    machineBits, sourceDir, testDir, sources, nativeBindings, generation:{exhaustiveLimit:1}};
  const result = JSON.parse(execFileSync(compiler, [], {input:JSON.stringify(request),
    encoding:'utf8', maxBuffer:32*1024*1024}));
  assert.deepEqual(result.diagnostics, []);
  assert.deepEqual(await wasm.planGeneration(request), result, 'Python native/WASM binding parity');
  const bridge = result.files.find(file => file.path.endsWith('example/payments.py'));
  assert.equal(bridge.ownership, 'generated');
  assert.ok(!bridge.content.includes('NotImplementedError'));
  for (const file of result.files) {
    const destination = path.join(output, file.path);
    await mkdir(path.dirname(destination), {recursive:true});
    await writeFile(destination, file.content);
  }
  const domainPath = path.join(output, sourceDir, 'payments_domain.py');
  await writeFile(domainPath, domain);
  await writeFile(path.join(output, testDir, 'test_native_bindings.py'),
    await readFile(path.join(root, 'test/runtime/PythonNativeBindingsCheck.py')));
  await writeFile(path.join(output, testDir, 'test_native_generators.py'),
    await readFile(path.join(root, 'test/runtime/PythonNativeGeneratorsCheck.py')));
  if (nativeBindings.generators) {
    if (scaffold) {
      const stub = result.files.find(file=>file.path===`${testDir}/lawspec_generators.py`);
      assert.equal(stub.ownership,'user');
      assert.equal(stub.placement,'test');
      const check = spawnSync(python,['-B','-c',`
from pathlib import Path
from hypothesis import strategies as st

namespace = {}
exec(compile(Path(${JSON.stringify(`${testDir}/lawspec_generators.py`)}).read_text(),
             "generator scaffold", "exec"), namespace)
for name, arguments in (("prices", ()), ("small_integers", ()), ("units", ()),
                        ("lists", (st.integers(),))):
    try:
        namespace[name](*arguments)
    except NotImplementedError as error:
        assert "Implement generator for" in str(error)
    else:
        raise AssertionError("An unimplemented factory must fail explicitly")
`],{cwd:output,encoding:'utf8',env:{...process.env,
        PYTHONPATH:process.env.LAWSPEC_PYTHON_DEPS ?? path.join(root,'.artifacts/python-data-deps')}});
      assert.equal(check.status,0,(check.stdout??'')+(check.stderr??''));
      console.log(`Python ${machineBits}, minify=${minify}: user-owned factory scaffolds compile and fail explicitly`);
      await writeFile(path.join(output,testDir,'test_generator_scaffold.py'),
        await readFile(path.join(root,'test/runtime/PythonGeneratorScaffoldCheck.py')));
    }
    await writeFile(path.join(output, testDir, 'lawspec_generators.py'),
      await readFile(path.join(fixture, 'generators.py'),'utf8') +
      (scaffold ? '\n\nlist_factories = 0\n\n\ndef lists(argument_0):\n' +
        '    global list_factories\n    list_factories += 1\n' +
        '    return st.lists(argument_0, max_size=5)\n' : ''));
    await writeFile(path.join(output, testDir, 'test_bound_generator.py'),
      await readFile(path.join(root, 'test/runtime/PythonBoundGeneratorCheck.py')));
  }
  const run = async label => {
    const execution = spawnSync(python, ['-B', '-m', 'pytest', '-q', '--tb=short', '-x', testDir], {
      cwd:output, encoding:'utf8', maxBuffer:32*1024*1024,
      env:{...process.env,PYTHONDONTWRITEBYTECODE:'1',PYTHONPATH:
        [path.join(output,sourceDir),path.join(output,testDir),
          process.env.LAWSPEC_PYTHON_DEPS ?? path.join(root,'.artifacts/python-data-deps'),
          process.env.PYTHONPATH ?? ''].filter(Boolean).join(path.delimiter)},
    });
    const log = (execution.stdout ?? '') + (execution.stderr ?? '');
    await writeFile(path.join(output, `${label}.log`), log);
    return {...execution, log};
  };
  const correct = await run('correct');
  assert.equal(correct.status,0,correct.log);
  console.log(`Python ${machineBits}, minify=${minify}: application types pass`);
  if (machineBits === 64 && !minify) try {
    for (const [name,before,after] of [
      ['wrong-fee','Fraction(1, 5)','Fraction(3, 10)'],
      ['currency-loss','unit=price.unit','unit=Dollars()'],
      ['absence-loss','return payments','return []'],
    ]) {
      assert.ok(domain.includes(before));
      await writeFile(domainPath,domain.replace(before,after));
      const broken = await run(name);
      assert.equal(broken.status,1,broken.log);
      assert.match(broken.log,/FAILED/);
      assert.doesNotMatch(broken.log,/ERROR collecting/);
      console.log(`Python: ${name} rejected by an executable law`);
    }
  } finally { await writeFile(domainPath,domain); }
}
