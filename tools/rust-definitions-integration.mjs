import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, mkdtemp, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {templates} from '../npm/templates.mjs';
import {planWrites, applyWrites} from '../npm/files.mjs';

const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
assert.ok(compiler, 'Set LAWSPEC_CORE');
const source = await readFile(path.join(root, 'test/fixtures/total_definitions.lawspec'), 'utf8');
const other = 'unit other\ndefinition genericIdentity (x :: a) :: a is x end\ndefinition genericCount (xs :: List a) :: BigInt is match xs with | Nil -> 0 | Cons head tail -> 1 + genericCount tail end end\nlaw `generic booleans` is definition is `for all` (xs :: List Bool) . genericCount xs = prelude.length xs end end\nlaw `generic texts` is definition is `for all` (xs :: List Text where genericCount xs > 0) . genericCount xs = prelude.length xs end end\ndefinition size (x :: Bool) :: Bool is genericIdentity x end\nlaw `identity` is definition is `for all` (x :: Bool where genericIdentity x) . size x = x end end';
// This shape-only fixture installs a runtime predicate below to isolate context
// plumbing from constructor-predicate emission, which has a separate rollout.
const identitySource = `unit identity
 type Identity is Identity value :: Symbol end
 definition echo (box :: Identity) :: Identity is box end
`;
const nativeBits = Number(execFileSync('rustc', ['--print', 'cfg'], {encoding: 'utf8'})
  .match(/target_pointer_width="(32|64)"/)[1]);
const profiles = process.env.LAWSPEC_MACHINE_BITS ? [Number(process.env.LAWSPEC_MACHINE_BITS)] : [32, 64];
for (const machineBits of profiles) {
  const sourceDir = machineBits === 32 ? 'library/native' : 'src';
  const testDir = machineBits === 32 ? 'checks/properties' : 'tests';
  const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target: 'rust', machineBits, sourceDir, testDir,
    sources: [{path: 'total.lawspec', content: source},
      {path: 'other.lawspec', content: other},
      {path: 'identity.lawspec', content: identitySource}],
  }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
  assert.deepEqual(result.diagnostics, []);
  const directory = path.join(root, `.artifacts/rust-definitions/${machineBits}`);
  const tests = result.files.filter(file => file.path.endsWith('_lawspec.rs'));
  const scaffold = templates('rust');
  await mkdir(path.join(directory, sourceDir), {recursive: true});
  await writeFile(path.join(directory, 'Cargo.toml'), scaffold['Cargo.toml'] +
    `\n[lib]\npath="${sourceDir}/lib.rs"\n` +
    tests.map((file, i) => `\n[[test]]\nname="laws_${i}"\npath="${file.path}"\n`).join(''));
  await writeFile(path.join(directory, sourceDir, 'lib.rs'), scaffold['src/lib.rs'] +
    '\n#[cfg(test)]\nmod definition_checks;\n');
  let adapterPath;
  let adapterSource;
  let definitionsPath;
  let definitionsSource;
  for (const file of result.files) {
    assert.ok(file.path.startsWith(`${file.placement === 'test' ? testDir : sourceDir}/`));
    const destination = path.join(directory, file.path);
    await mkdir(path.dirname(destination), {recursive: true});
    let content = file.content;
    if (file.ownership === 'user') {
      assert.doesNotMatch(content, /pub fn (size|sumList|sumTree|increment|forward|divisible|machine)\(/);
      content = content.replace('todo!("example.total::actualSum")', 'value0.into_iter().map(ls::BigInt::from).sum()')
        .replace('todo!("example.total::actualIncrement")', 'ls::BigInt::from(value0) + 1')
        .replace('todo!("example.total::actualTree")', `{
          fn sum(tree: crate::lawspec_data::Tree) -> ls::BigInt {
            match tree {
              crate::lawspec_data::Tree::Leaf { value } => ls::BigInt::from(value),
              crate::lawspec_data::Tree::Branch { left, right } => sum(*left) + sum(*right),
            }
          }
          sum(value0)
        }`);
      if (file.path.endsWith('/example/total.rs')) {
        adapterPath = destination;
        adapterSource = content;
      }
    }
    if (file.path.endsWith('/lawspec_definitions.rs')) {
      assert.equal(file.ownership, 'generated');
      assert.equal(file.placement, 'source');
      assert.doesNotMatch(content, /proptest|adapter::|todo!/);
      definitionsPath = destination;
      definitionsSource = content;
      // Preserve both versions to make formatter differences reviewable.
      const formatted = execFileSync('rustfmt', ['--edition', '2024'], {input: content, encoding: 'utf8'});
      await writeFile(path.join(directory, 'definitions.rustfmt.rs'), formatted);
      await writeFile(path.join(directory, 'definitions.generated.rs'), content);
      assert.ok(content === formatted, `Definitions must match rustfmt; inspect ${directory}/definitions.{generated,rustfmt}.rs`);
    }
    await writeFile(destination, content);
  }
  assert.ok(adapterPath && definitionsPath);
  const nativeChecks = (await readFile(path.join(root, 'test/runtime/RustDefinitionsCheck.rs'), 'utf8'))
    .replaceAll('MACHINE_COMPATIBLE', String(machineBits === nativeBits));
  await writeFile(path.join(directory, sourceDir, 'definition_checks.rs'), nativeChecks);
  async function run(label, filter = []) {
    const result = spawnSync('cargo', ['test', '--offline', '--quiet', ...filter], {
      cwd: directory, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
      env: {...process.env, CARGO_TARGET_DIR: path.join(root, '.artifacts/rust-definitions/target')},
    });
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(directory, `${label}.log`), log);
    return {...result, log};
  }
  const correct = await run('correct');
  assert.equal(correct.status, 0, correct.log);
  const target = tests.findIndex(file => file.path.endsWith('/example_total_lawspec.rs'));
  assert.ok(target >= 0);
  for (const [label, from, to, test] of [
    ['sum', 'value0.into_iter().map(ls::BigInt::from).sum()', 'ls::BigInt::from(0)', 'test_0'],
    ['overflow', 'ls::BigInt::from(value0) + 1', 'ls::BigInt::from(value0.wrapping_add(1))', 'test_1'],
    ['tree', 'sum(value0)', 'ls::BigInt::from(0)', 'test_2'],
  ]) {
    const mutant = adapterSource.replace(from, to);
    assert.notEqual(mutant, adapterSource);
    await writeFile(adapterPath, mutant);
    const result = await run(label, ['--test', `laws_${target}`, test]);
    assert.notEqual(result.status, 0, `mutant exposed: ${label}`);
    assert.match(result.log, /test result: FAILED/);
    assert.doesNotMatch(result.log, /error\[E\d+\]/);
  }
  await writeFile(adapterPath, adapterSource);
  await writeFile(definitionsPath, definitionsSource);
  const fixture = process.env.LAWSPEC_RUST_DEFINITIONS_FIXTURE;
  assert.ok(fixture, 'Set LAWSPEC_RUST_DEFINITIONS_FIXTURE to test compact source');
  const inputPath = path.join(directory, 'total.lawspec');
  const otherPath = path.join(directory, 'other.lawspec');
  await writeFile(inputPath, source);
  await writeFile(otherPath, other);
  const identityPath = path.join(directory, 'identity.lawspec');
  await writeFile(identityPath, identitySource);
  execFileSync(fixture, [String(machineBits), definitionsPath, inputPath, otherPath, identityPath]);
  const compactSource = await readFile(definitionsPath, 'utf8');
  assert.notEqual(compactSource, definitionsSource);
  assert.ok(compactSource.length < definitionsSource.length);
  const compact = await run('compact');
  assert.equal(compact.status, 0, compact.log);
  await writeFile(definitionsPath, definitionsSource);
  // Compile the reusable source with no property-framework dependency declared.
  const nativeOnly = path.join(directory, 'native-only');
  await mkdir(nativeOnly, {recursive: true});
  await writeFile(path.join(nativeOnly, 'Cargo.toml'),
    scaffold['Cargo.toml'].split('[dev-dependencies]')[0] +
    `\n[lib]\npath="../${sourceDir}/lib.rs"\n`);
  const standalone = spawnSync('cargo', ['test', '--offline', '--quiet', '--lib'], {
    cwd: nativeOnly, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
    env: {...process.env, CARGO_TARGET_DIR: path.join(root, '.artifacts/rust-definitions/target')},
  });
  await writeFile(path.join(directory, 'native-only.log'),
    (standalone.stdout ?? '') + (standalone.stderr ?? ''));
  assert.equal(standalone.status, 0, standalone.stdout + standalone.stderr);
  const lock = await readFile(path.join(nativeOnly, 'Cargo.lock'), 'utf8');
  assert.doesNotMatch(lock, /name = "proptest"/);
  // Install a context-sensitive predicate and execute the real native API.
  // Each mutant independently resets one boundary's context; all must fail.
  const schemaPath = path.join(directory, sourceDir, 'lawspec_schema.rs');
  const schemaSource = await readFile(schemaPath, 'utf8');
  const contractSchema = schemaSource.replace('ls::Schema::new(', 'ls::Schema::with_contracts(')
    .replace(/\]\)\n}\n$/, `], vec![ls::ConstructorContract {
        tag: "identity::type::Identity::Identity",
        predicates: vec![|_, _, fields, _, ctx| {
            Ok(fields[0] == ls::Value::Symbol(ctx.symbol("fixture", "same")))
        }],
    }])
}
`);
  assert.notEqual(contractSchema, schemaSource);
  const checksPath = path.join(directory, sourceDir, 'definition_checks.rs');
  const identityCheck = `
#[test]
fn constructor_identity_context() -> ls::Result<()> {
    use crate::lawspec_data::Identity;
    use crate::lawspec_definitions::identity;
    let ctx = &mut ls::Context::default();
    let symbol = ctx.symbol("fixture", "same");
    let result = identity::echo(ctx, Identity::Identity { value: symbol.clone() })?;
    assert!(matches!(result, Identity::Identity { value } if value == symbol));
    let wrong = ls::Context::default().symbol("fixture", "same");
    assert!(identity::echo(ctx, Identity::Identity { value: wrong }).is_err());
    Ok(())
}
`;
  try {
    await writeFile(schemaPath, contractSchema);
    await writeFile(checksPath, nativeChecks + identityCheck);
    const valid = await run('identity-context', ['--lib', 'constructor_identity_context']);
    assert.equal(valid.status, 0, valid.log);
    await writeFile(definitionsPath, compactSource);
    const compactIdentity = await run('identity-context-compact', ['--lib', 'constructor_identity_context']);
    assert.equal(compactIdentity.status, 0, compactIdentity.log);
    for (const [label, argument] of [
      ['argument', String.raw`validate_with_context\(\s*arguments\.next\(\)\.unwrap\(\),`],
      ['result', String.raw`validate_with_context\(\s*result,`],
      ['native', String.raw`native_value_with_context\(\s*result,`],
    ]) {
      const matcher = new RegExp(String.raw`(schema\.${argument}[^;]*?,\s*)ctx(,?\s*\))`, 'g');
      const mutant = definitionsSource.replace(matcher, '$1&mut ls::Context::default()$2');
      assert.notEqual(mutant, definitionsSource, `context mutant applied: ${label}`);
      await writeFile(definitionsPath, mutant);
      const rejected = await run(`identity-${label}-mutant`, ['--lib', 'constructor_identity_context']);
      assert.notEqual(rejected.status, 0);
      assert.match(rejected.log, /test result: FAILED/);
      assert.doesNotMatch(rejected.log, /error\[E\d+\]/);
    }
  } finally {
    await writeFile(schemaPath, schemaSource);
    await writeFile(checksPath, nativeChecks);
    await writeFile(definitionsPath, definitionsSource);
  }
  // Test ownership through the actual writer, separately from the Cargo fixture.
  const regeneration = await mkdtemp(path.join(directory, 'regeneration-'));
  await applyWrites([await planWrites(regeneration, result.files)]);
  const adapter = result.files.find(file => file.path.endsWith('/example/total.rs'));
  const definitionFile = result.files.find(file => file.path.endsWith('/lawspec_definitions.rs'));
  await writeFile(path.join(regeneration, adapter.path), adapterSource);
  const unchanged = await planWrites(regeneration, result.files);
  assert.equal(unchanged.changes.length, 0);
  assert.equal(await readFile(path.join(regeneration, adapter.path), 'utf8'), adapterSource);
  await writeFile(path.join(regeneration, definitionFile.path), '// edited generated definition\n');
  await assert.rejects(planWrites(regeneration, result.files), /edited generated file/);
  console.log(`Rust total definitions, native entry points, properties, identity contexts and six mutants passed: ${machineBits}`);
}
