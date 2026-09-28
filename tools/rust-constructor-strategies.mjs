import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_RUST_CONSTRUCTOR_FIXTURE;
assert.ok(fixture, 'Set LAWSPEC_RUST_CONSTRUCTOR_FIXTURE');
const base = path.join(root, '.artifacts/rust-constructor-strategies');
execFileSync(fixture, [path.join(root, 'test/fixtures/python_constructor_fields.lawspec'), base]);
for (const bits of [32, 64]) for (const mode of ['pretty', 'compact']) {
  const directory = path.join(base, String(bits), mode);
  const runtime = await readFile(path.join(root, 'runtime/lawspec_strategies.rs'), 'utf8');
  await writeFile(path.join(directory, 'src/lawspec_strategies.rs'), runtime);
  const checks = await readFile(path.join(root, 'test/runtime/RustConstructorStrategiesCheck.rs'), 'utf8');
  await writeFile(path.join(directory, 'src/lib.rs'), '#![cfg(test)]\n' + checks.replaceAll('MACHINE_BITS', String(bits)));
  await writeFile(path.join(directory, 'Cargo.toml'), `[package]
name = "lawspec-constructor-strategies"
version = "0.0.0"
edition = "2024"
publish = false
[dependencies]
num-bigint = "=0.4.8"
num-rational = "=0.4.2"
num-complex = "=0.4.6"
num-traits = "=0.2.19"
[dev-dependencies]
proptest = "=1.11.0"
`);
  const run = async (label, filter = []) => {
    const result = spawnSync('cargo', ['test', '--offline', '--quiet', ...filter], {
      cwd: directory, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024,
      env: {...process.env, CARGO_TARGET_DIR: path.join(base, 'target')},
    });
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(directory, `${label}.log`), log);
    return {...result, log};
  };
  const result = await run('test');
  assert.equal(result.status, 0, result.log);
  for (const [label, from, to, test] of [
    ['hidden-error', 'Err(error) => Some(Err(error))', 'Err(_) => None',
      'evaluator_errors_are_visible_during_generation_and_shrinking'],
    ['symbol-reset', '&mut context.clone()', '&mut ls::Context::default()',
      'nested_symbol_witnesses_keep_native_length_shrinking'],
  ]) {
    const mutant = runtime.replaceAll(from, to);
    assert.notEqual(mutant, runtime);
    try {
      await writeFile(path.join(directory, 'src/lawspec_strategies.rs'), mutant);
      const result = await run(label, [test]);
      assert.notEqual(result.status, 0, `exposes ${label}`);
      assert.match(result.log, /test result: FAILED/);
      assert.doesNotMatch(result.log, /error\[E\d+\]/);
    } finally {
      await writeFile(path.join(directory, 'src/lawspec_strategies.rs'), runtime);
    }
  }
  console.log(`Rust checked generation, witnesses, shrinking and two mutants passed: ${bits} ${mode}`);
}
