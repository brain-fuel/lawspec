// Execute compiler-generated native bridges against one application library.
import assert from 'node:assert/strict';
import {spawnSync, execFileSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {templates} from '../npm/templates.mjs';
import {createCompiler} from '../npm/api.mjs';

const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
assert.ok(compiler, 'Set LAWSPEC_CORE to the current native compiler');
const wasm = await createCompiler();
const fixture = path.join(root, 'test/fixtures/native-payments');
const content = await readFile(path.join(root, 'examples/specs/payments.lawspec'), 'utf8');
const nativeBindings = JSON.parse(await readFile(path.join(fixture, 'bindings.json'), 'utf8'));
if (process.env.LAWSPEC_NATIVE_GENERATORS === '1') nativeBindings.generators = [{
  type: 'example.payments::type::Money', factory: ['lawspec_generators', 'prices'],
}];
const domain = await readFile(path.join(fixture, 'domain.rs'), 'utf8');
for (const machineBits of [32, 64]) {
  const sourceDir = machineBits === 32 ? 'library/native' : 'src';
  const testDir = machineBits === 32 ? 'checks/native' : 'tests';
  const output = path.join(root, `.artifacts/native-bound-payments/${machineBits}`);
  const request = {schemaVersion: 4, method: 'planGeneration', target: 'rust', machineBits,
    sourceDir, testDir, sources: [{path: 'payments.lawspec', content}], nativeBindings};
  const result = JSON.parse(execFileSync(compiler, [], {
    input: JSON.stringify(request),
    encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
  }));
  assert.deepEqual(result.diagnostics, []);
  if (process.env.LAWSPEC_SKIP_WASM_PARITY !== '1')
    assert.deepEqual(await wasm.planGeneration(request), result, "Native/WASM binding parity");
  const adapter = result.files.find(file => file.path.endsWith('example/payments.rs'));
  assert.equal(adapter.ownership, 'generated', 'Bound adapters must be generated bridges');
  assert.ok(!adapter.content.includes('todo!'));
  const tests = result.files.filter(file => file.path.endsWith('_lawspec.rs'));
  for (const file of result.files) {
    const destination = path.join(output, file.path);
    await mkdir(path.dirname(destination), {recursive: true});
    await writeFile(destination, file.content);
  }
  if (nativeBindings.generators) {
    await writeFile(path.join(output, testDir, 'support/lawspec_generators.rs'),
      await readFile(path.join(fixture, 'generators.rs')));
    const checks = await readFile(path.join(root, 'test/runtime/RustBoundGeneratorCheck.rs'), 'utf8');
    for (const file of tests) await writeFile(path.join(output, file.path), file.content + '\n' + checks);
  }
  const scaffold = templates('rust');
  await writeFile(path.join(output, 'Cargo.toml'), scaffold['Cargo.toml'] +
    `\n[lib]\npath="${sourceDir}/lib.rs"\n` + tests.map((file, index) =>
      `\n[[test]]\nname="payments_${index}"\npath="${file.path}"\n`).join(''));
  await writeFile(path.join(output, sourceDir, 'lib.rs'),
    'include!("lawspec_modules.rs");\npub mod domain;\n');
  const domainPath = path.join(output, sourceDir, 'domain.rs');
  await writeFile(domainPath, domain);
  const run = async label => {
    const result = spawnSync('cargo', ['test', '--offline', '--quiet'], {
      cwd: output, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
      env: {...process.env, CARGO_TARGET_DIR: path.join(root, '.artifacts/native-bound-payments/target')},
    });
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(output, label + '.log'), log);
    return {...result, log};
  };
  const correct = await run('correct');
  assert.equal(correct.status, 0, correct.log);
  console.log(`Rust ${machineBits}: generated native bridges and shared application-library types pass`);
  if (machineBits === 64) {
    try {
      for (const [name, before, after] of [
        ['wrong-fee', 'Decimal::new(2.into(), (-1).into())', 'Decimal::new(3.into(), (-1).into())'],
        ['currency-loss', '    price\n', '    price.unit = CurrencyCode::Dollars;\n    price\n'],
        ['absence-loss', '    payments\n', '    payments.into_iter().filter(Option::is_some).collect()\n'],
      ]) {
        assert.ok(domain.includes(before));
        await writeFile(domainPath, domain.replace(before, after));
        const broken = await run(name);
        assert.notEqual(broken.status, 0);
        assert.match(broken.log, /test result: FAILED/, `${name} must fail a law, not compilation`);
        console.log(`Rust: ${name} rejected through generated native bridge`);
      }
    } finally {
      await writeFile(domainPath, domain);
    }
  }
}
