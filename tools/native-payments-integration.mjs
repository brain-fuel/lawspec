// Baseline for 0.10: a real application model behind the existing checked bridge.
// This deliberately uses a manual adapter until native binding generation lands.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';
import {templates, targets} from '../npm/templates.mjs';

const root = path.resolve(import.meta.dirname, '..');
const output = path.join(root, '.artifacts/native-payments');
const fixture = path.join(root, 'test/fixtures/native-payments');
const compiler = await createCompiler();
const sources = [{path: 'payments.lawspec', content:
  await readFile(path.join(root, 'examples/specs/payments.lawspec'), 'utf8')}];
let rust;
for (const target of targets) {
  const result = await compiler.planGeneration({sources, target});
  assert.deepEqual(result.diagnostics, [], `${target} generation diagnostics`);
  assert.ok(result.files.some(file => file.ownership === 'user'));
  if (target === 'rust') rust = result;
  console.log(`${target}: payment model checked and generation planned`);
}
for (const file of [
  ...Object.entries(templates('rust')).map(([path, content]) => ({path, content})),
  ...rust.files,
]) {
  const destination = path.join(output, file.path);
  await mkdir(path.dirname(destination), {recursive: true});
  await writeFile(destination, file.content);
}
const adapter = rust.files.find(file => file.ownership === 'user');
await writeFile(path.join(output, adapter.path), await readFile(path.join(fixture, 'manual_adapter.rs')));
const domain = await readFile(path.join(fixture, 'domain.rs'), 'utf8');
const nativePath = path.join(output, 'src/domain.rs');
await writeFile(nativePath, domain);
function run() {
  return spawnSync('cargo', ['test', '--offline', '--quiet'], {
    cwd: output, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
    env: {...process.env, CARGO_TARGET_DIR: path.join(output, 'target')},
  });
}
let correct = run();
await writeFile(path.join(output, 'correct.log'), (correct.stdout ?? '') + (correct.stderr ?? ''));
assert.equal(correct.status, 0, correct.stdout + correct.stderr);
console.log('Rust: application-owned products, sums, renamed fields and nested containers pass');
const mutations = [
  ['wrong-fee', 'Decimal::new(2.into(), (-1).into())', 'Decimal::new(3.into(), (-1).into())'],
  ['currency-loss', '    price\n', '    price.unit = CurrencyCode::Dollars;\n    price\n'],
  ['absence-loss', '    payments\n', '    payments.into_iter().filter(Option::is_some).collect()\n'],
];
try {
  for (const [name, before, after] of mutations) {
    assert.ok(domain.includes(before), `Missing mutation anchor: ${name}`);
    await writeFile(nativePath, domain.replace(before, after));
    const result = run();
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(output, `${name}.log`), log);
    assert.notEqual(result.status, 0, `${name} escaped the laws`);
    assert.match(log, /test result: FAILED/, `${name} must fail a law, not compilation`);
    console.log(`Rust: ${name} rejected by generated laws`);
  }
} finally {
  await writeFile(nativePath, domain);
}
