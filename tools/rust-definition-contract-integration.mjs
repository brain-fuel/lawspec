import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_RUST_CONTRACT_FIXTURE;
assert.ok(fixture, 'Set LAWSPEC_RUST_CONTRACT_FIXTURE');
const base = path.join(root, `.artifacts/rust-definition-contracts${process.env.LAWSPEC_CONTRACT_SOURCE === '1' ? '-source' : ''}`);
execFileSync(fixture, [base]);
const source = `mod lawspec_runtime;
mod lawspec_definitions;
mod lawspec_schema {
    use crate::lawspec_runtime as ls;
    pub fn schema() -> ls::Result<ls::Schema> { ls::Schema::new(vec![]) }
}
use lawspec_runtime as ls;
use lawspec_definitions::fixture as native;
fn reject<T>(name: &str, stage: &str, result: ls::Result<T>) {
    match result {
        Err(message) => {
            assert!(message.contains(&format!("{name}:")), "{message}");
            assert!(message.contains(stage), "{message}");
            assert!(!message.contains("division by zero"), "{message}");
        }
        Ok(_) => panic!("accepted {name}"),
    }
}
fn main() {
    let ctx = &mut ls::Context::default();
    if std::env::var("CONTRACT_MUTANT").as_deref() == Ok("1") {
        reject("next", "postcondition", native::next(ctx, 1));
        return;
    }
    let mut visits = 0;
    let mut visit = |_| { visits += 1; assert_eq!(visits, 1); Ok(ls::Value::Bool(false)) };
    assert!(ls::all_elements(ls::Value::List(vec![]), &mut visit).unwrap().boolean().unwrap());
    assert!(!ls::all_elements(ls::Value::List(vec![ls::Value::Bool(false), ls::Value::Bool(true)]), &mut visit).unwrap().boolean().unwrap());
    assert_eq!(visits, 1);
    assert_eq!(native::sumreciprocal(ctx, vec![1, 2]).unwrap(), ls::BigRational::new(3.into(), 2.into()));
    assert_eq!(native::sumreciprocal(ctx, vec![]).unwrap(), ls::BigRational::new(0.into(), 1.into()));
    assert_eq!(native::sumrows(ctx, vec![vec![], vec![1, 2], vec![-2]]).unwrap(), ls::BigRational::new(1.into(), 1.into()));
    assert_eq!(native::positivetail(ctx, vec![1, 2]).unwrap(), vec![2]);
    assert_eq!(native::positivefirst(ctx, vec![]).unwrap(), 1);
    reject("sumreciprocal", "precondition", native::sumreciprocal(ctx, vec![1, 0]));
    reject("sumrows", "precondition", native::sumrows(ctx, vec![vec![0]]));
    assert_eq!(native::keep(ctx, vec![1, 2]).unwrap(), vec![1, 2]);
    assert_eq!(native::stronger(ctx, vec![11]).unwrap(), vec![11]);
    assert_eq!(native::reuse(ctx, vec![1]).unwrap(), vec![1]);
    assert!(native::empty(ctx, 0).unwrap().is_empty());
    assert_eq!(native::singleton(ctx, 1).unwrap(), vec![1]);
    reject("keep", "precondition", native::keep(ctx, vec![1, 0]));
    reject("stronger", "precondition", native::stronger(ctx, vec![1]));
    reject("reuse", "precondition", native::reuse(ctx, vec![0]));
    assert!(native::allpositive(ctx, vec![]).unwrap());
    assert!(native::allpositive(ctx, vec![1, 2]).unwrap());
    assert!(!native::allpositive(ctx, vec![0, -1]).unwrap());
    assert!(native::nestedabove(ctx, vec![vec![], vec![3, 4]]).unwrap());
    assert!(!native::nestedabove(ctx, vec![vec![1, 2]]).unwrap());
    assert_eq!(native::next(ctx, 127).unwrap(), ls::Integer(128.into()));
    assert_eq!(native::caller(ctx, 1).unwrap(), ls::Integer(2.into()));
    assert_eq!(native::ordered(ctx, 2).unwrap(), 2);
    assert_eq!(native::narrow(ctx, 126).unwrap(), 127);
    assert_eq!(native::reciprocal(ctx, 2).unwrap(), ls::BigRational::new(1.into(), 2.into()));
    reject("next", "precondition", native::next(ctx, 0));
    reject("caller", "precondition", native::caller(ctx, 0));
    reject("reciprocal", "precondition", native::reciprocal(ctx, 0));
    reject("ordered", "precondition", native::ordered(ctx, 0));
    reject("ordered", "precondition", native::ordered(ctx, -1));
    reject("narrow", "precondition", native::narrow(ctx, 127));
    reject("next", "precondition", lawspec_definitions::evaluate_0(ctx, vec![ls::Value::Integer(0.into())]));
}
`;
for (const bits of [32, 64]) for (const mode of ['pretty', 'compact']) {
  const directory = path.join(base, String(bits), mode);
  await writeFile(path.join(directory, 'Cargo.toml'), `[package]
name = "lawspec-contract-fixture"
version = "0.0.0"
edition = "2024"
publish = false
[dependencies]
num-bigint = "=0.4.8"
num-rational = "=0.4.2"
num-complex = "=0.4.6"
num-traits = "=0.2.19"
`);
  await writeFile(path.join(directory, 'src/main.rs'), source);
  const body = path.join(directory, 'src/lawspec_definitions.rs');
  const original = await readFile(body, 'utf8');
  if (mode === 'pretty') {
    const formatted = execFileSync('rustfmt', ['--edition', '2024'], {input: original, encoding: 'utf8'});
    await writeFile(path.join(directory, 'definitions.rustfmt.rs'), formatted);
    assert.equal(original, formatted);
  }
  const run = mutant => execFileSync('cargo', ['run', '--offline', '--quiet'], {
    cwd: directory, env: {...process.env, CONTRACT_MUTANT: mutant ? '1' : '',
      CARGO_TARGET_DIR: path.join(base, 'target')}, stdio: 'inherit',
  });
  run(false);
  const start = original.indexOf('pub(crate) fn evaluate_0(');
  const end = original.indexOf('pub(crate) fn evaluate_1(');
  assert.ok(start >= 0 && end > start);
  const method = original.slice(start, end);
  const changed = method.replace(/let result = \{[\s\S]*?\n(\s*)let checked =/, 'let result = ls::Value::Integer(0.into());\n$1let checked =');
  assert.notEqual(changed, method);
  try { await writeFile(body, original.slice(0, start) + changed + original.slice(end)); run(true); }
  finally { await writeFile(body, original); }
  console.log(`rust ${bits} ${mode}: native contracts, direct logical checks and corrupted-result rejection passed`);
}
