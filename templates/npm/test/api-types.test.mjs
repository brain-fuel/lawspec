// The published TypeScript declarations admit an exhaustive visitor over the
// expression types (test/fixtures/payload_api.ts). Skipped without tsc.
import {canonicalRequest, legacyCheck} from './legacy-input.mjs';
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {existsSync} from 'node:fs';
import {mkdtemp, readFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {pathToFileURL} from 'node:url';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '../..');
const local = path.join(root, '.integration/typescript/node_modules/.bin/tsc');
const tsc = process.env.LAWSPEC_TSC ?? (existsSync(local) ? local : null);

test('published expression types pass exhaustive TypeScript visitor checks', {skip: tsc === null && 'tsc is not installed'}, () => {
  execFileSync(tsc, [
    '--noEmit', '--strict', '--target', 'ES2022', '--module', 'NodeNext',
    '--moduleResolution', 'NodeNext', 'test/fixtures/payload_api.ts',
  ], {cwd: root, stdio: 'pipe'});
});

test('the exhaustive TypeScript visitor traverses emitted records, effects and failure handlers', {skip: tsc === null && 'tsc is not installed'}, async t => {
  const directory = await mkdtemp(path.join(tmpdir(), 'lawspec-expression-types-'));
  t.after(() => rm(directory, {recursive: true, force: true}));
  execFileSync(tsc, ['--strict', '--target', 'ES2022', '--module', 'NodeNext', '--moduleResolution', 'NodeNext',
    '--rootDir', 'test/fixtures', '--outDir', directory, 'test/fixtures/payload_api.ts'], {cwd: root, stdio: 'pipe'});
  const {children, nodeFixtures, sourceFieldMigrations, symbolicMigrationEvidence, nativeBindingMigration} = await import(pathToFileURL(path.join(directory, 'payload_api.js')).href);
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  const expressions = [];
  function collect(value) {
    if (value === null || typeof value !== 'object') return;
    if (value.type && typeof value.text === 'string' && typeof value.node?.kind === 'string') expressions.push(value);
    for (const child of Object.values(value)) collect(child);
  }
  for (const fixture of ['rc1/parcel-measurements', 'specs/abilities', 'specs/failures']) {
    const file = path.join(root, 'examples', fixture + '.lawspec');
    const content = await readFile(file, 'utf8') + (fixture === 'specs/abilities'
      ? '\ndefinition handledCheckout (cents :: Int32) :: Bool is handle checkout cents with fakeGateway end end\n' : '');
    // Historical effect fixtures use migration; canonical records use the ordinary API.
    const request = {sources: [{path: file, content}]};
    const result = fixture.startsWith('rc1/')
      ? await compiler.expand({...canonicalRequest, ...request})
      : await legacyCheck(compiler, request);
    assert.deepEqual(result.diagnostics, [], fixture);
    collect(result);
  }
  assert.ok(expressions.length > 0);
  const kinds = new Set(), handlers = new Set(), callFilters = new Set();
  for (const expression of expressions) {
    const node = expression.node;
    kinds.add(node.kind);
    if (node.kind === 'handle') handlers.add(node.handling);
    if (node.kind === 'calls') callFilters.add(node.arguments === null ? 'all' : 'matching');
    const descendants = children(node);
    assert.ok(Array.isArray(descendants), node.kind);
    for (const child of descendants) {
      assert.ok(child.type && child.origin && child.node && typeof child.text === 'string', node.kind);
    }
  }
  for (const kind of ['field', 'let', 'if', 'perform', 'handle', 'calls']) assert.ok(kinds.has(kind), kind);
  assert.deepEqual([...handlers].sort(), ['catchFailure', 'withHandler']);
  assert.deepEqual([...callFilters].sort(), ['all', 'matching']);
  const value = expressions.find(e => e.node.kind === 'constant');
  assert.ok(value);
  const fixtures = nodeFixtures(value, {binder: {id: 'value', name: 'value', type: value.type}, predicate: value});
  const update = fixtures.find(node => node.kind === 'update');
  assert.deepEqual(children(update), [value, value]);
  assert.deepEqual(children(fixtures.find(node => node.kind === 'if')), [value, value, value]);
  assert.throws(() => children({kind: 'future-node'}), /Unrecognized expression node/);
  const options = {schemaVersion: 5, languageProfile: '1.0-rc.1', verification: {layers: []}};
  const original = [{path: 'fields.lawspec', content: 'unit fields\n' +
    'type Capsule (a :: Type) is Packed last :: Bool first :: a end\n' +
    'definition read (input :: Capsule a) :: a is input.first end'}];
  const baseline = await compiler.migrationBaseline({...options, from: '0.24', sources: original});
  assert.deepEqual(baseline.diagnostics, []);
  assert.deepEqual(sourceFieldMigrations(baseline), ['fields::type::Capsule::Packed:first']);
  const migrated = [{path: 'fields.lawspec', content: 'unit fields\n' +
    'type Capsule (a :: Type) is one of Packed of type record{last :: Bool first :: a} end type\n' +
    'function read (input :: Capsule a) -> a is input.value.first end function'}];
  const comparison = await compiler.migrationComparison({...options, from: '0.24', sources: original,
    migrated: {...options, sources: migrated}});
  assert.deepEqual(comparison.diagnostics, []);
  const fingerprints = symbolicMigrationEvidence(comparison);
  assert.equal(fingerprints.length, 5);
  assert.ok(fingerprints.every(value => /^[0-9a-f]{64}$/.test(value)));
  const nativeProposal = await compiler.migrationBindings({...options, from: '0.24', target: 'python', sources: original,
    migrated: {...options, sources: migrated}});
  assert.deepEqual(nativeProposal.diagnostics, []);
  assert.deepEqual(nativeBindingMigration(nativeProposal), ['python', 'not-established']);
  t.diagnostic(`Traversed ${expressions.length} emitted expressions across ${kinds.size} node kinds; both handler forms and call filters were present.`);
});
