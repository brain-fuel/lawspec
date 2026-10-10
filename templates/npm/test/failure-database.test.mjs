import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mkdir, mkdtemp, readFile, readdir, rm, writeFile} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {failureDatabase, projectKey} from '../failure-database.mjs';

async function fixture(t) {
  const directory = await mkdtemp(path.join(os.tmpdir(), 'lawspec-failure-database-'));
  t.after(() => rm(directory, {recursive: true, force: true}));
  return directory;
}

test('failure seeds belong to the language and project root', async t => {
  const root = await fixture(t);
  const first = await failureDatabase(root, 'erlang', path.join(root, 'first'));
  const second = await failureDatabase(root, 'erlang', path.join(root, 'second'));
  const another = await failureDatabase(root, 'elixir', path.join(root, 'first'));
  assert.equal(new Set([first.directory, second.directory, another.directory]).size, 3);
  await writeFile(first.file, JSON.stringify({'unit::law::check': {seed: 911}}));
  assert.deepEqual((await failureDatabase(root, 'erlang', path.join(root, 'first'))).database,
    {'unit::law::check': {seed: 911}});
  assert.deepEqual((await failureDatabase(root, 'erlang', path.join(root, 'second'))).database, {});
  assert.equal(projectKey(path.join(root, 'first')), projectKey(path.join(root, 'first', '.')));
});

test('legacy seeds and all runtime counterexamples migrate once without changing originals', async t => {
  const root = await fixture(t), legacy = path.join(root, '.lawspec/failures/rust');
  const inputs = {'inputs/law.json': '[1]', 'hypothesis/key/example': 'native example',
    'proptest-regressions.txt': 'seed regression', 'laws.json': '{"law":{"seed":42}}'};
  for (const [file, contents] of Object.entries(inputs)) {
    await mkdir(path.dirname(path.join(legacy, file)), {recursive: true});
    await writeFile(path.join(legacy, file), contents);
  }
  const first = await failureDatabase(root, 'rust', path.join(root, 'first'));
  assert.deepEqual(first.database, {law: {seed: 42}});
  for (const [file, contents] of Object.entries(inputs)) {
    assert.equal(await readFile(path.join(legacy, file), 'utf8'), contents);
    if (file !== 'laws.json') assert.equal(await readFile(path.join(first.directory, file), 'utf8'), contents);
  }
  await writeFile(first.file, '{}');
  await rm(path.join(first.directory, 'inputs'), {recursive: true});
  assert.deepEqual((await failureDatabase(root, 'rust', path.join(root, 'first'))).database, {});
  await assert.rejects(readFile(path.join(first.directory, 'inputs/law.json')), {code: 'ENOENT'});
  const second = await failureDatabase(root, 'rust', path.join(root, 'second'));
  assert.deepEqual(second.database, {law: {seed: 42}});
  assert.equal(await readFile(path.join(second.directory, 'inputs/law.json'), 'utf8'), '[1]');
  assert.ok(!(await readdir(legacy)).some(name => name.startsWith('.migrate-')));
});

test('initialization handles concurrent callers without mixing project state', async t => {
  const root = await fixture(t);
  const results = await Promise.all(Array.from({length: 8}, () => failureDatabase(root, 'gleam', root)));
  assert.equal(new Set(results.map(result => result.directory)).size, 1);
  assert.ok(results.every(result => Object.keys(result.database).length === 0));
  assert.deepEqual(await readdir(path.join(root, '.lawspec/failures/gleam')), [projectKey(root)]);
});

test('malformed legacy or scoped databases fail without discarding their contents', async t => {
  const root = await fixture(t), legacy = path.join(root, '.lawspec/failures/python');
  await mkdir(legacy, {recursive: true});
  const file = path.join(legacy, 'laws.json');
  await writeFile(file, 'broken json');
  await assert.rejects(failureDatabase(root, 'python', root), SyntaxError);
  assert.deepEqual(await readdir(legacy), ['laws.json']);
  await writeFile(file, '[]');
  await assert.rejects(failureDatabase(root, 'python', root), /map of law identities/);
  await writeFile(file, '{}');
  const scoped = await failureDatabase(root, 'python', root);
  await writeFile(scoped.file, 'null');
  await assert.rejects(failureDatabase(root, 'python', root), /map of law identities/);
  assert.equal(await readFile(scoped.file, 'utf8'), 'null');
});
