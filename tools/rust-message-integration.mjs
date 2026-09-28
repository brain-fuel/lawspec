// Verify generated literal chunks and contextual failures using Rust itself.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {templates} from '../npm/templates.mjs';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
assert.ok(compiler, 'Set LAWSPEC_CORE');
const label = 'a descriptive diagnostic with apostrophes \' and quotes " and backslashes \\ plus supplementary Unicode 🙂 preserved exactly';
const payload = 'fixture: a long literal with repeated spaces   quotes " backslashes \\ and supplementary Unicode 🙂 must arrive unchanged ' + '🙂'.repeat(40);
const integers = [-(2n ** 127n) - 1n, -(2n ** 127n), 2n ** 127n - 1n, 2n ** 127n,
  -(2n ** 256n), 2n ** 256n];
const source = `unit diagnostic
echo :: Text -> Text
parseInteger :: Text -> BigInt
law \`${label}\` is
  definition is \`for all\` (x :: Text) . echo x = x end
  example \`literal\` is x = ${JSON.stringify(payload)} expect echo x = ${JSON.stringify(payload)} end
end
${integers.map((value, i) => `law \`integer representation ${i}\` is
definition is \`for all\` (marker :: Unit) . parseInteger "${value}" = ${value} end end`).join('\n')}`;
// Independent raw literals in the checking adapter do not use compiler escaping.
const raw = value => {
  assert.ok(!value.includes('"###'));
  return `r###"${value}"###`;
};
for (const minify of [false, true]) {
  const directory = path.join(root, '.artifacts/rust-messages', minify ? 'compact' : 'readable');
  const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target: 'rust', minify, sources: [{path: 'diagnostic', content: source}],
  }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
  assert.deepEqual(result.diagnostics, []);
  const scaffold = templates('rust', {minify});
  for (const file of [
    ...Object.entries(scaffold).map(([path, content]) => ({path, content})), ...result.files,
  ]) {
    const destination = path.join(directory, file.path);
    await mkdir(path.dirname(destination), {recursive: true});
    await writeFile(destination, file.content);
  }
  const adapter = result.files.find(file => file.ownership === 'user');
  const adapterPath = path.join(directory, adapter.path);
  const nativeAdapter = `pub fn echo(value: String) -> String {
    if value.starts_with("fixture:") { assert_eq!(value, ${raw(payload)}); }
    value
}
pub fn parseInteger(value: String) -> crate::lawspec_runtime::BigInt {
    value.parse().unwrap()
}
`;
  await writeFile(adapterPath, nativeAdapter);
  const environment = {...process.env, CARGO_TARGET_DIR: path.join(root, '.artifacts/rust-messages/target')};
  const run = args => execFileSync('cargo', ['test', '--offline', '--quiet', ...args], {
    cwd: directory, env: environment, stdio: 'inherit',
  });
  run([]);
  const test = result.files.find(file => file.path.endsWith('_lawspec.rs'));
  const diagnosticCheck = `
#[test]
fn diagnostic_payload() {
    let mut context = lawspec_runtime::Context::default();
    let error = law_0(&mut context, lawspec_runtime::Value::Text("probe".to_owned())).unwrap_err();
    assert!(error.starts_with(${raw(label + ' | expect echo (_input0) = _input0: ')}), "{error}");
}
`;
  await writeFile(path.join(directory, test.path), test.content + diagnosticCheck);
  await writeFile(adapterPath, nativeAdapter.replace('    value\n', '    value + "broken"\n'));
  try { run(['diagnostic_payload']); }
  finally {
    await writeFile(adapterPath, nativeAdapter);
    await writeFile(path.join(directory, test.path), test.content);
  }
  console.log(`Rust ${minify ? 'compact' : 'readable'}: native literals and diagnostic text preserved`);
}
