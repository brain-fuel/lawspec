// The published TypeScript declarations admit an exhaustive visitor over the
// expression types (test/fixtures/payload_api.ts). Skipped without tsc.
import {canonicalRequest, checkInput} from './compiler-input.mjs';
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {existsSync} from 'node:fs';
import {mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {pathToFileURL} from 'node:url';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '../..');
const local = path.join(root, '.integration/typescript/node_modules/.bin/tsc');
const tsc = process.env.LAWSPEC_TSC ?? (existsSync(local) ? local : null);

test('recorded native outcomes retain history without widening newly produced outcomes', {skip: tsc === null && 'tsc is not installed'}, () => {
  execFileSync(tsc, ['--noEmit', '--strict', '--target', 'ES2022', '--module', 'NodeNext',
    '--moduleResolution', 'NodeNext', 'test/fixtures/native_observation_api.ts'], {cwd: root, stdio: 'pipe'});
});

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
  const {children, nodeFixtures} = await import(pathToFileURL(path.join(directory, 'payload_api.js')).href);
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
    const sourceText = await readFile(file, 'utf8');
    const content = (fixture === 'specs/abilities' ? sourceText.replace(/end unit\s*$/u, '') : sourceText) + (fixture === 'specs/abilities'
      ? `
function handledCheckout (cents :: Int32) -> Bool is handle checkout cents with fakeGateway end handle end function

end unit
` : '');
    // Every fixture uses the current compiler interface.
    const request = {sources: [{path: file, content}]};
    const result = fixture.startsWith('rc1/')
      ? await compiler.expand({...canonicalRequest, ...request})
      : await checkInput(compiler, request);
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
  t.diagnostic(`Traversed ${expressions.length} emitted expressions across ${kinds.size} node kinds; both handler forms and call filters were present.`);
});


test('published component and completed evidence types resolve through package exports', {skip: tsc === null && 'tsc is not installed'}, async t => {
  const directory = await mkdtemp(path.join(root, 'npm/.component-types-'));
  t.after(() => rm(directory, {recursive: true, force: true}));
  const file = path.join(directory, 'consumer.mts');
  await writeFile(file, `
import {resolveComponent, type ComponentManifest, type ComponentDescriptor} from 'lawspec/component';
import type {AttestationView, NativeExecutionAttempt} from 'lawspec';
const manifest: ComponentManifest = {
  manifestVersion: 1, languageProfile: '1.0-rc.2', sources: ['src'],
  component: {name: 'bank', version: '1.0.0'},
  targets: [{language: 'rust', root: '.', cargo: 'cargo'}],
  dependencies: {api: {version: '^1.0.0', git: 'https://example.com/api.git'}},
};
const resolved: Promise<ComponentDescriptor> = resolveComponent('lawspec.edn', {locked: true});
declare const evidence: AttestationView;
declare const attempt: NativeExecutionAttempt;
const status: 'wired' | 'running' | 'completed' | undefined = evidence.run.execution?.status;
const fingerprint: string | undefined = evidence.application?.component?.fingerprint;
const executionRun: string | undefined = attempt.executionRun;
export {manifest, resolved, status, fingerprint, executionRun};
`);
  execFileSync(tsc, ['--noEmit', '--strict', '--target', 'ES2022', '--module', 'NodeNext',
    '--moduleResolution', 'NodeNext', file], {cwd: root, stdio: 'pipe'});
});
