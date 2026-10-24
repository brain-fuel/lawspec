import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, writeFile, mkdir, rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {parseManifest, writeManifest, readManifest, findManifest, resolveComponent} from '../component.mjs';

const project = {manifestVersion: 1, component: {name: 'example', version: '0.1.0'}, languageProfile: '1.0-rc.2', sources: ['laws'], targets: [{language: 'javascript', root: '.'}]};
async function directory(t) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-component-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  return root;
}

test('manifest EDN preserves nested binding keys, Unicode and enum values', () => {
  const value = {...project, targets: [{language: 'rust', root: '.', nativeBindings: {functions: [{declaration: 'example::read', native: ['example', 'read']}], types: []}}]};
  assert.deepEqual(parseManifest(writeManifest(value)), value);
  assert.equal(parseManifest('{:component {:name "λ" :version "0.1.0"} :manifest-version 1}').component.name, 'λ');
});

test('EDN duplicate and normalized duplicate keys are rejected before conversion', () => {
  for (const text of ['{:sources [] :sources ["other"]}', '{:source-dir "a" :sourceDir "b"}'])
    assert.throws(() => parseManifest(text), /duplicate/i);
});

test('EDN must be exactly one complete data map and never evaluates tags', () => {
  for (const text of ['{:name "unfinished"', '{} {}', '[{}]', '{:x #=(println "never")}', '{:x (code)}', '{:x symbol}', '{:x #{1 2}}'])
    assert.throws(() => parseManifest(text), /complete|map|unsupported|one/i);
  assert.deepEqual(parseManifest('{} ; trailing comment'), {});
});

test('manifest discovery ascends to the nearest component and rejects JSON', async t => {
  const root = await directory(t);
  await mkdir(path.join(root, 'laws/nested'), {recursive: true});
  await writeFile(path.join(root, 'lawspec.edn'), writeManifest(project));
  assert.equal(await findManifest(path.join(root, 'laws/nested')), path.join(root, 'lawspec.edn'));
  await writeFile(path.join(root, 'laws/lawspec.json'), '{}');
  await assert.rejects(findManifest(path.join(root, 'laws')), /lawspec\.edn/);
});

test('readManifest reports independent manifest validation failures', async t => {
  const root = await directory(t), file = path.join(root, 'lawspec.edn');
  await writeFile(file, '{:manifest-version 1 :component {:name "" :version "bad"} :sources false :targets []}');
  await assert.rejects(readManifest(file), error => error.diagnostics.length >= 3);
});

test('resolved component describes checked laws, fingerprints and declaration reliance', async t => {
  const root = await directory(t), file = path.join(root, 'lawspec.edn');
  await mkdir(path.join(root, 'laws'));
  await writeFile(path.join(root, 'laws/example.lawspec'), 'unit example\nread :: Unit -> Int32\nlaw "|the recorded answer| is definition: read unitValue = 42 end definition end law\nend unit\n');
  await writeFile(file, writeManifest(project));
  const described = await resolveComponent(file);
  assert.equal(described.format, 'lawspec-component');
  assert.equal(described.version, 1);
  assert.equal(described.component.name, 'example');
  assert.equal(described.laws.length, 1);
  assert.match(described.fingerprint, /^[a-f0-9]{64}$/);
  const previous = described.fingerprint;
  await writeFile(path.join(root, 'laws/example.lawspec'), 'unit example\nread :: Unit -> Int32\nlaw "|the recorded answer| is definition: read unitValue = 43 end definition end law\nend unit\n');
  assert.notEqual((await resolveComponent(file)).fingerprint, previous);
});

test('descriptions validate native bindings even with optional verification disabled', async t => {
  const root = await directory(t), file = path.join(root, 'lawspec.edn');
  await mkdir(path.join(root, 'laws'));
  await writeFile(path.join(root, 'laws/example.lawspec'), 'unit example\nread :: Unit -> Int32\nend unit\n');
  await writeFile(file, writeManifest({...project, verification: {layers: []}, targets: [{language: 'javascript', root: '.', nativeBindings: {functions: [{declaration: 'example::missing', native: ['example', 'read']}]}}]}));
  await assert.rejects(resolveComponent(file), /missing|unknown|binding/i);
});
