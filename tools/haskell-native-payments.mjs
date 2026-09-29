import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile, rm} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const generatorStubs = process.env.LAWSPEC_GENERATOR_STUBS === '1';
const nativeGenerators = generatorStubs || process.env.LAWSPEC_NATIVE_GENERATORS === '1';
const ghc = process.env.LAWSPEC_GHC;
assert.ok(compiler && ghc, 'Set LAWSPEC_CORE and LAWSPEC_GHC');
const packageArgs = process.env.LAWSPEC_GHC_PACKAGE_DB
  ? ['-package-db', process.env.LAWSPEC_GHC_PACKAGE_DB] : [];
const read = name => readFile(path.join(root, name), 'utf8');
const {createCompiler} = await import('../npm/api.mjs');
const wasm = await createCompiler();
const content = (await read('examples/specs/payments.lawspec'))
  .replace('roundTrip :: Payment -> Payment', 'roundTrip :: (x :: Payment) -> (result :: Payment where result == x)') + `
complete :: Unit -> Unit
law \`completed operation\` is definition is \`for all\` (x :: Unit) . complete x = x end end
`;
const bindings = JSON.parse(await read('test/fixtures/native-payments/bindings-haskell.json'));
bindings.functions.push({declaration: 'example.payments::complete', native: ['PaymentsDomain', 'complete']});
const shapes = (await read('test/fixtures/native_shapes.lawspec')) + `
type Identity is Identity value :: (s :: Symbol where s == symbol("fixture", "same")) end
copyIdentity :: Identity -> Identity
law \`native scoped constructor contract\` is
  definition is \`for all\` (x :: Identity) . copyIdentity x = x end
end
`;
const shapeBindings = JSON.parse(await read('test/fixtures/native-shapes/bindings-haskell.json'));
shapeBindings.functions.forEach(binding => { binding.native = ['P', 'copy']; });
shapeBindings.types.push({type: 'native.shapes::type::Identity', native: ['P', 'Claim'], constructors: [
  {constructor: 'Identity', native: ['P', 'Claim'], style: 'record', fields: [{field: 'value', native: 'token'}]},
]});
shapeBindings.functions.push({declaration: 'native.shapes::copyIdentity', native: ['P', 'copy']});
bindings.types.push(...shapeBindings.types);
bindings.functions.push(...shapeBindings.functions);
if (nativeGenerators) bindings.generators = [
  {type: 'example.payments::type::Money', factory: ['PaymentGenerators', 'prices']},
  {type: 'native.shapes::type::Box', factory: ['PaymentGenerators', 'boxes']},
  {type: 'Int8', factory: ['PaymentGenerators', 'bytes']},
  {type: 'native.shapes::type::Stamp', factory: ['PaymentGenerators', 'seals']},
];
if (generatorStubs) bindings.generators.forEach(binding => { binding.stub = true; });
const shapeDomain = await read('test/fixtures/native-shapes/ShapesDomain.hs');
const domain = (await read('test/fixtures/native-payments/PaymentsDomain.hs')) + '\ncomplete :: () -> ()\ncomplete value = value\n';
for (const machineBits of [32, 64]) for (const minify of [false, true]) {
  const sourceDir = machineBits === 32 ? 'library/native' : 'src';
  const testDir = machineBits === 32 ? 'checks/generated' : 'test';
  const directory = path.join(root, `.artifacts/haskell-native-payments${generatorStubs ? '-stubs' : nativeGenerators ? '-generators' : ''}/${machineBits}/${minify ? 'compact' : 'pretty'}`);
  if (generatorStubs) await rm(directory, {recursive: true, force: true});
  const request = {
    schemaVersion: 4, method: 'planGeneration', target: 'haskell', machineBits, minify,
    generation: {exhaustiveLimit: 1, maxAttempts: nativeGenerators ? 100 : 1000},
    sourceDir, testDir, nativeBindings: bindings, sources: [{path: 'payments.lawspec', content}, {path: 'shapes.lawspec', content: shapes}],
  };
  const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify(request), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024}));
  assert.deepEqual(await wasm.planGeneration(request), result, 'Haskell native/WASM binding parity');
  assert.deepEqual(result.diagnostics, []);
  for (const file of result.files) {
    const destination = path.join(directory, file.path);
    await mkdir(path.dirname(destination), {recursive: true});
    await writeFile(destination, file.content);
  }
  const domainPath = path.join(directory, sourceDir, 'PaymentsDomain.hs');
  await writeFile(domainPath, domain);
  await writeFile(path.join(directory, sourceDir, 'ShapesDomain.hs'), shapeDomain);
  await writeFile(path.join(directory, sourceDir, 'P.hs'), await read('test/fixtures/native-shapes/P.hs'));
  if (generatorStubs) {
    const args = [...packageArgs, `-i${sourceDir}`, `-i${testDir}`, '-outputdir', 'scaffold-build'];
    const compilation = spawnSync(ghc, [...args, '--make', '-fno-code', ...result.files.map(file => file.path)],
      {cwd: directory, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024});
    await writeFile(path.join(directory, 'scaffold-build.log'), compilation.stdout + compilation.stderr);
    assert.equal(compilation.status, 0, compilation.stdout + compilation.stderr);
    await writeFile(path.join(directory, 'ScaffoldCheck.hs'), `module Main where
import Control.Exception (SomeException, evaluate, try)
import Data.List (isInfixOf)
import qualified PaymentGenerators
main :: IO ()
main = do
  result <- try (evaluate PaymentGenerators.prices >> pure ()) :: IO (Either SomeException ())
  case result of
    Left exception | "Implement generator for" \`isInfixOf\` show exception -> pure ()
    _ -> error "unimplemented factory must fail explicitly"
`);
    execFileSync(ghc, [...args, '--make', 'ScaffoldCheck.hs', '-o', 'scaffold-check'], {cwd: directory, encoding: 'utf8'});
    execFileSync(path.join(directory, 'scaffold-check'), [], {cwd: directory, encoding: 'utf8'});
  }
  if (nativeGenerators) await writeFile(path.join(directory, testDir, 'PaymentGenerators.hs'),
    await read('test/fixtures/native-payments/PaymentGenerators.hs'));
  if (nativeGenerators) {
    const sourceCheck = spawnSync(ghc, ['--make', '-fno-code', '-hide-all-packages',
      '-package', 'base', '-package', 'text', '-package', 'bytestring', `-i${sourceDir}`,
      '-outputdir', 'source-build', ...result.files.filter(file => file.placement === 'source').map(file => file.path)],
      {cwd: directory, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024});
    await writeFile(path.join(directory, 'source-only.log'), sourceCheck.stdout + sourceCheck.stderr);
    assert.equal(sourceCheck.status, 0, sourceCheck.stdout + sourceCheck.stderr);
    await writeFile(path.join(directory, 'NativeSourceCheck.hs'), await read('test/runtime/HaskellNativeBindingsCheck.hs'));
    const sourceBuild = spawnSync(ghc, ['--make', 'NativeSourceCheck.hs', '-hide-all-packages',
      '-package', 'base', '-package', 'text', '-package', 'bytestring', `-i${sourceDir}`,
      '-outputdir', 'source-build', '-o', 'source-check'],
      {cwd: directory, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024});
    await writeFile(path.join(directory, 'source-check-build.log'), sourceBuild.stdout + sourceBuild.stderr);
    assert.equal(sourceBuild.status, 0, sourceBuild.stdout + sourceBuild.stderr);
    const sourceRun = spawnSync(path.join(directory, 'source-check'), [String(machineBits)],
      {cwd: directory, encoding: 'utf8'});
    await writeFile(path.join(directory, 'source-check.log'), sourceRun.stdout + sourceRun.stderr);
    assert.equal(sourceRun.status, 0, sourceRun.stdout + sourceRun.stderr);
  }
  if (nativeGenerators) await writeFile(path.join(directory, 'HaskellBoundGeneratorsCheck.hs'),
    await read('test/runtime/HaskellBoundGeneratorsCheck.hs'));
  await writeFile(path.join(directory, 'Main.hs'),
    'module Main where\nimport Test.Hspec\nimport qualified Example.PaymentsSpec as Payments\nimport qualified Native.ShapesSpec as Shapes\n' +
    (nativeGenerators ? `import HaskellBoundGeneratorsCheck (checkFactories)\nmain = checkFactories ${machineBits} >> hspec (Payments.spec >> Shapes.spec)\n` :
      'main = hspec (Payments.spec >> Shapes.spec)\n'));
  function run(label) {
    const build = spawnSync(ghc, [...packageArgs, '--make', 'Main.hs', `-i${sourceDir}`, `-i${testDir}`,
      '-O0', '-outputdir', 'build', '-o', 'check'], {cwd: directory, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024});
    return writeFile(path.join(directory, `${label}-build.log`), build.stdout + build.stderr).then(async () => {
      assert.equal(build.status, 0, build.stdout + build.stderr);
      const test = spawnSync(path.join(directory, 'check'), [], {cwd: directory, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024});
      await writeFile(path.join(directory, `${label}.log`), test.stdout + test.stderr);
      return test;
    });
  }
  const correct = await run('correct');
  assert.equal(correct.status, 0, correct.stdout + correct.stderr);
  for (const [label, before, after] of [
    ['unit', 'complete value = value', 'complete value = error \"application Unit failure\"'],
    ['fee', 'amount + 1 % 5', 'amount + 1 % 4'],
    ['currency', 'value { major =', 'value { unit = Dollars, major ='],
    ['absence', 'store values = values', 'store values = [value | value@(Just _) <- values]'],
  ]) {
    assert.ok(domain.includes(before));
    await writeFile(domainPath, domain.replace(before, after));
    const mutant = await run(label);
    assert.notEqual(mutant.status, 0, `${label} escaped its laws`);
    assert.match(mutant.stdout + mutant.stderr, /Failures:|Failed/);
  }
  await writeFile(domainPath, domain);
  if (nativeGenerators) {
    const mainPath = path.join(directory, 'Main.hs');
    const main = await readFile(mainPath, 'utf8');
    await writeFile(mainPath, main.replace(`checkFactories ${machineBits} >> `, ''));
    const generatorPath = path.join(directory, testDir, 'PaymentGenerators.hs');
    const generators = await read('test/fixtures/native-payments/PaymentGenerators.hs');
    for (const [label, before, after, expected] of [
      ['invalid-generator', 'cents % 100', 'cents % 3', /native generator:/],
      ['exhausted-refinement', 'Gen.int8 (Range.linear 6 20)', 'pure 0', /[Gg]ave up/],
    ]) {
      assert.ok(generators.includes(before));
      await writeFile(generatorPath, generators.replace(before, after));
      const failed = await run(label);
      assert.notEqual(failed.status, 0, `${label} escaped its laws`);
      assert.match(failed.stdout + failed.stderr, expected);
    }
    await writeFile(generatorPath, generators);
    await writeFile(mainPath, main);
  }
  console.log(`Haskell native payments: ${machineBits} bits, ${minify ? 'compact' : 'pretty'}, four mutants rejected`);
}
