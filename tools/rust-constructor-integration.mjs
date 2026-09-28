import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_RUST_CONSTRUCTOR_FIXTURE;
assert.ok(fixture, 'Set LAWSPEC_RUST_CONSTRUCTOR_FIXTURE');
const base = path.join(root, '.artifacts/rust-constructor-fields');
await mkdir(base, {recursive: true});
const input = path.join(base, 'fields.lawspec');
await writeFile(input, await readFile(path.join(root,
  'test/fixtures/python_constructor_fields.lawspec'), 'utf8') + `
type Same is Same first :: Float64 second :: (x :: Float64 where x == first) end
definition echoSame (pair :: Same) :: Same is pair end
`);
execFileSync(fixture, [input, base]);
const checks = await readFile(path.join(root, 'test/runtime/RustGeneratedConstructorCheck.rs'), 'utf8');
for (const bits of [32, 64]) for (const mode of ['pretty', 'compact']) {
  const directory = path.join(base, String(bits), mode);
  await writeFile(path.join(directory, 'Cargo.toml'), `[package]
name = "lawspec-constructor-fixture"
version = "0.0.0"
edition = "2024"
publish = false
[dependencies]
num-bigint = "=0.4.8"
num-rational = "=0.4.2"
num-complex = "=0.4.6"
num-traits = "=0.2.19"
`);
  await writeFile(path.join(directory, 'src/main.rs'), checks);
  for (const name of ['lawspec_data', 'lawspec_schema', 'lawspec_definitions']) {
    const source = await readFile(path.join(directory, `src/${name}.rs`), 'utf8');
    const formatted = execFileSync('rustfmt', ['--edition', '2024'], {input: source, encoding: 'utf8'});
    if (mode === 'pretty') {
      await writeFile(path.join(directory, `${name}.rustfmt.rs`), formatted);
      assert.equal(source, formatted, `${name} matches rustfmt`);
    } else {
      const pretty = await readFile(path.join(base, String(bits), 'pretty', `src/${name}.rs`), 'utf8');
      assert.equal(formatted, pretty, `${name} compact token/layout parity`);
    }
  }
  const run = async label => {
    const result = spawnSync('cargo', ['run', '--offline', '--quiet'], {
      cwd: directory, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024,
      env: {...process.env, MACHINE_BITS: String(bits), CARGO_TARGET_DIR: path.join(base, 'target')},
    });
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(directory, `${label}.log`), log);
    return {...result, log};
  };
  const correct = await run('correct');
  assert.equal(correct.status, 0, correct.log);
  const schemaPath = path.join(directory, 'src/lawspec_schema.rs');
  const schema = await readFile(schemaPath, 'utf8');
  // Predicates that accept everything or use a new Symbol context must both fail.
  for (const [label, from, to] of [
    ['accept-all', 'accepted.boolean()', 'Ok(true)'],
    ['symbol-reset', 'ctx.symbol("fixture", "same")', 'ls::Context::default().symbol("fixture", "same")'],
  ]) {
    const mutant = schema.replaceAll(from, to);
    assert.notEqual(mutant, schema);
    try {
      await writeFile(schemaPath, mutant);
      const result = await run(label);
      assert.notEqual(result.status, 0, `exposes ${label}`);
      assert.doesNotMatch(result.log, /error\[E\d+\]/);
      assert.match(result.log, /invalid constructor accepted|field refinement|exact division by zero/);
    } finally {
      await writeFile(schemaPath, schema);
    }
  }
  console.log(`Rust emitted constructor callbacks, native APIs and two mutants passed: ${bits} ${mode}`);
}
