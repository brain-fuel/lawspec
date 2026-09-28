import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {readFile, readdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {templates} from '../npm/templates.mjs';

const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_PAYLOAD_FIXTURE;
assert.ok(fixture, 'Set LAWSPEC_PAYLOAD_FIXTURE');
const scaffold = templates('rust');
const check = `
use crate::{lawspec_data as data, lawspec_definitions::payload as defs, lawspec_runtime as ls};
fn leaf(value: i8) -> data::Tree<i8> { data::Tree::Leaf { value, fixed: -128 } }
#[test]
fn native_payload_definitions() -> ls::Result<()> {
    let mut ctx = ls::Context::default();
    let value = data::Tree::Node { children: vec![leaf(2), leaf(3)] };
    assert!(defs::above(&mut ctx, value.clone(), 1)?);
    assert!(!defs::above(&mut ctx, value.clone(), 2)?);
    assert!(defs::positive(&mut ctx, vec![])?);
    assert!(defs::positive(&mut ctx, vec![1, 2])?);
    assert!(!defs::positive(&mut ctx, vec![1, 0])?);
    defs::identity(&mut ctx, data::Pack::Pack { tree: value })?;
    assert!(defs::identity(&mut ctx, data::Pack::Pack { tree: leaf(0) }).unwrap_err().contains("field refinement"));
    defs::genericIdentity(&mut ctx, data::GenericPack::GenericPack { tree: leaf(0) })?;
    let shared = ctx.symbol("shared", "description");
    assert!(defs::shared(&mut ctx, vec![shared])?);
    let different = ctx.symbol("different", "description");
    assert!(!defs::shared(&mut ctx, vec![different])?);
    Ok(())
}
`;
async function files(dir) {
  const result = [];
  for (const entry of await readdir(dir, {withFileTypes: true})) {
    const file = path.join(dir, entry.name);
    if (entry.isDirectory()) result.push(...await files(file));
    else if (entry.name.endsWith('.rs')) result.push(file);
  }
  return result;
}
for (const bits of [32, 64]) for (const compact of [false, true]) for (const builtins of [false, true]) {
  const directory = path.join(root, `.artifacts/rust-payload-emission/${bits}-${compact}-${builtins}`);
  execFileSync(fixture, [String(bits), compact ? 'True' : 'False', directory,
    'rust', ...(builtins ? ['builtins'] : [])]);
  const generated = [...await files(path.join(directory, 'src')), ...await files(path.join(directory, 'tests'))];
  const property = await readFile(path.join(directory, 'tests/payload_lawspec.rs'), 'utf8');
  assert.match(property, /all_payloads_with_context/);
  assert.match(property, /proptest::test_runner::TestRunner/);
  for (const file of generated.filter(file => !["lib.rs", "payload_checks.rs"].includes(path.basename(file)))) {
    const content = await readFile(file, 'utf8');
    if (!compact) {
      const formatted = execFileSync('rustfmt', ['--edition', '2024', '--config', 'skip_children=true'], {
        input: content, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024,
      });
      assert.equal(content, formatted, file);
    }
  }
  await writeFile(path.join(directory, 'Cargo.toml'), scaffold['Cargo.toml']);
  await writeFile(path.join(directory, 'src/lib.rs'), scaffold['src/lib.rs'] +
    (builtins ? '' : '\n#[cfg(test)]\nmod payload_checks;\n'));
  if (!builtins) await writeFile(path.join(directory, 'src/payload_checks.rs'), check);
  const result = spawnSync('cargo', ['test', '--offline', '--quiet'], {
    cwd: directory, encoding: 'utf8', timeout: 60000, maxBuffer: 4 * 1024 * 1024,
    env: {...process.env, CARGO_TARGET_DIR: path.join(root, '.artifacts/rust-payload-emission/target')},
  });
  await writeFile(path.join(directory, 'check.log'), (result.stdout ?? '') + (result.stderr ?? ''));
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stdout + result.stderr);
}
console.log('Rust payload definitions, generic constructors, Symbol context and properties pass eight width/layout/domain configurations; rustfmt passes');
