import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, mkdir, readFile, writeFile, rm} from 'node:fs/promises';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createServer} from 'node:http';
import os from 'node:os';
import path from 'node:path';
import * as tar from 'tar';
import {writeManifest, readManifest, parseManifest, contentDigest} from '../component.mjs';
import {resolveDependencies, packComponent} from '../component-packages.mjs';

const exec = promisify(execFile);
async function setup(t) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-published-'));
  const previous = process.env.LAWSPEC_CACHE_DIR;
  process.env.LAWSPEC_CACHE_DIR = path.join(root, 'cache');
  t.after(async () => {
    if (previous === undefined) delete process.env.LAWSPEC_CACHE_DIR;
    else process.env.LAWSPEC_CACHE_DIR = previous;
    await rm(root, {recursive: true, force: true});
  });
  return root;
}
async function contract(root, name, version = '1.0.0', dependencies = {}) {
  await mkdir(path.join(root, 'laws'), {recursive: true});
  await writeFile(path.join(root, 'laws/model.lawspec'), `unit ${name}\nfunction answer (u :: Unit) -> Int32 is 42 end function\nend unit\n`);
  await writeFile(path.join(root, 'lawspec.edn'), writeManifest({manifestVersion: 1, package: {name, version}, languageProfile: '1.0-rc.2', sources: ['laws'], dependencies}));
  return root;
}
async function consumer(root, dependencies) {
  await mkdir(root, {recursive: true});
  const file = path.join(root, 'lawspec.edn');
  const manifest = {manifestVersion: 1, component: {name: 'consumer', version: '0.1.0'}, languageProfile: '1.0-rc.2', sources: [], targets: [], dependencies};
  await writeFile(file, writeManifest(manifest));
  return {file, manifest};
}
async function git(root, ...args) {
  return (await exec('git', ['-C', root, ...args])).stdout.trim();
}
async function publish(root, version) {
  await git(root, 'add', '.');
  await git(root, '-c', 'user.name=LawSpec Test', '-c', 'user.email=test@example.invalid', 'commit', '--quiet', '-m', version);
  await git(root, 'tag', 'v' + version);
}
async function resolve(project, options) {return resolveDependencies(project.file, project.manifest, options);}

test('local contracts resolve transitively; source edits update evidence without changing the lock', async t => {
  const root = await setup(t);
  await contract(path.join(root, 'leaf'), 'example.leaf');
  await contract(path.join(root, 'parent'), 'example.parent', '1.0.0', {'example.leaf': {version: '^1.0.0', path: '../leaf'}});
  const project = await consumer(path.join(root, 'consumer'), {'example.parent': {version: '^1.0.0', path: '../parent'}});
  const first = await resolve(project);
  assert.deepEqual(first.packages.map(item => item.name), ['example.leaf', 'example.parent']);
  const lock = await readFile(path.join(path.dirname(project.file), 'lawspec.lock.edn'), 'utf8');
  await writeFile(path.join(root, 'leaf/laws/model.lawspec'), 'unit example.leaf\nfunction answer (u :: Unit) -> Int32 is 43 end function\nend unit\n');
  const changed = await resolve(project, {locked: true});
  assert.notEqual(changed.identities.find(item => item.name === 'example.leaf').digest, first.identities.find(item => item.name === 'example.leaf').digest);
  assert.equal(await readFile(path.join(path.dirname(project.file), 'lawspec.lock.edn'), 'utf8'), lock);
});

test('a missing lock and incompatible local versions cannot pass --locked', async t => {
  const root = await setup(t);
  await contract(path.join(root, 'library'), 'example.library');
  const project = await consumer(path.join(root, 'consumer'), {'example.library': {version: '^2.0.0', path: '../library'}});
  await assert.rejects(resolve(project, {locked: true}), /Lockfile must change/);
  await assert.rejects(resolve(project), /requires example.library.*version 1.0.0/);
});

test('package dependency cycles are rejected', async t => {
  const root = await setup(t);
  await contract(path.join(root, 'a'), 'example.a', '1.0.0', {'example.b': {version: '^1.0.0', path: '../b'}});
  await contract(path.join(root, 'b'), 'example.b', '1.0.0', {'example.a': {version: '^1.0.0', path: '../a'}});
  const project = await consumer(path.join(root, 'consumer'), {'example.a': {version: '^1.0.0', path: '../a'}});
  await assert.rejects(resolve(project), /dependency cycle/);
});

test('Git tags select the highest matching version; locks survive new tags and support offline replay', async t => {
  const root = await setup(t), repository = await contract(path.join(root, 'git'), 'example.library');
  await exec('git', ['init', '--quiet', repository]);
  await publish(repository, '1.0.0');
  await contract(repository, 'example.library', '1.1.0');
  await publish(repository, '1.1.0');
  const project = await consumer(path.join(root, 'consumer'), {'example.library': {version: '^1.0.0', git: repository}});
  const first = await resolve(project);
  assert.equal(first.packages[0].version, '1.1.0');
  assert.match(first.identities[0].source.commit, /^[a-f0-9]{40,64}$/);
  await contract(repository, 'example.library', '1.2.0');
  await publish(repository, '1.2.0');
  assert.equal((await resolve(project, {locked: true, offline: true})).packages[0].version, '1.1.0');
  const updated = await exec(process.execPath, [new URL('../bin/lawspec.mjs', import.meta.url).pathname, 'update', 'example.library', '--config', project.file, '--json'], {cwd: path.dirname(project.file)});
  assert.equal(JSON.parse(updated.stdout).packages[0].version, '1.2.0');
  const lock = parseManifest(await readFile(path.join(root, 'consumer/lawspec.lock.edn'), 'utf8'));
  assert.equal(lock.packages[0].version, '1.2.0');
});

test('Git package subdirectories and custom tag prefixes retain their declared identities', async t => {
  const root = await setup(t), repository = path.join(root, 'git');
  await contract(path.join(repository, 'contracts/library'), 'example.library', '2.0.0');
  await exec('git', ['init', '--quiet', repository]);
  await git(repository, 'add', '.');
  await git(repository, '-c', 'user.name=LawSpec Test', '-c', 'user.email=test@example.invalid', 'commit', '--quiet', '-m', 'library');
  await git(repository, 'tag', 'library/v2.0.0');
  const project = await consumer(path.join(root, 'consumer'), {'example.library': {version: '^2.0.0', git: repository, subdir: 'contracts/library', tagPrefix: 'library/v'}});
  const result = await resolve(project);
  assert.equal(result.packages[0].version, '2.0.0');
  assert.equal(result.identities[0].source.subdir, 'contracts/library');
});

test('published archives are deterministic, checked by SHA-256 and replayable offline', async t => {
  const root = await setup(t), directory = await contract(path.join(root, 'package'), 'example.library');
  const first = await packComponent(path.join(directory, 'lawspec.edn'), path.join(root, 'first.tgz'));
  const second = await packComponent(path.join(directory, 'lawspec.edn'), path.join(root, 'second.tgz'));
  assert.equal(first.sha256, second.sha256);
  const bytes = await readFile(first.file);
  const server = createServer((_, response) => {response.end(bytes);});
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => {server.closeAllConnections(); return new Promise(resolve => server.close(resolve));});
  const archive = `http://127.0.0.1:${server.address().port}/contract.tgz`;
  const project = await consumer(path.join(root, 'consumer'), {'example.library': {version: '^1.0.0', archive, sha256: first.sha256}});
  assert.equal((await resolve(project)).packages[0].name, 'example.library');
  assert.equal((await resolve(project, {locked: true, offline: true})).packages[0].version, '1.0.0');
  const bad = await consumer(path.join(root, 'bad'), {'example.library': {version: '^1.0.0', archive, sha256: '0'.repeat(64)}});
  await assert.rejects(resolve(bad), /SHA-256 mismatch/);
});

test('archives cannot write through a symbolic link outside their package', async t => {
  const root = await setup(t), directory = await contract(path.join(root, 'package'), 'example.library');
  const {symlink} = await import('node:fs/promises');
  await symlink(root, path.join(directory, 'escape'));
  const archive = path.join(root, 'unsafe.tgz');
  await tar.c({cwd: directory, file: archive, gzip: true}, ['lawspec.edn', 'laws', 'escape']);
  const bytes = await readFile(archive);
  const server = createServer((_, response) => response.end(bytes));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => {server.closeAllConnections(); return new Promise(resolve => server.close(resolve));});
  const project = await consumer(path.join(root, 'consumer'), {'example.library': {version: '^1.0.0', archive: `http://127.0.0.1:${server.address().port}/unsafe.tgz`, sha256: contentDigest(bytes)}});
  await assert.rejects(resolve(project), /Unsafe package archive entry/);
});

test('Git tags cannot mislabel the manifest version', async t => {
  const root = await setup(t), repository = await contract(path.join(root, 'git'), 'example.library');
  await exec('git', ['init', '--quiet', repository]);
  await publish(repository, '1.9.0');
  const project = await consumer(path.join(root, 'consumer'), {'example.library': {version: '^1.0.0', git: repository}});
  await assert.rejects(resolve(project), /Git tag version 1.9.0 differs.*manifest version 1.0.0/);
});

test('package sources cannot escape through symbolic links', async t => {
  const root = await setup(t), directory = await contract(path.join(root, 'package'), 'example.library');
  const {symlink} = await import('node:fs/promises');
  await symlink(directory, path.join(directory, 'laws/loop'));
  await assert.rejects(packComponent(path.join(directory, 'lawspec.edn'), path.join(root, 'unsafe.tgz')), /symbolic links/);
});

test('invalid lock entries are rejected before dependency loading', async t => {
  const root = await setup(t);
  const project = await consumer(path.join(root, 'consumer'), {});
  await writeFile(path.join(root, 'consumer/lawspec.lock.edn'), writeManifest({format: 'lawspec-lock', version: 1, roots: {}, selections: {}, packages: [null]}));
  await assert.rejects(resolve(project), /Invalid LawSpec lockfile/);
});

test('resolved contract digests include the selected transitive contract closure', async t => {
  const root = await setup(t);
  const results = [];
  for (const [name,version] of [['a','1.0.0'], ['b','1.1.0']]) {
    await contract(path.join(root,name,'leaf'), 'example.leaf', version);
    await contract(path.join(root,name,'parent'), 'example.parent', '1.0.0', {'example.leaf': {version: '^1.0.0', path: '../leaf'}});
    const project = await consumer(path.join(root,name,'consumer'), {'example.parent': {version: '^1.0.0', path: '../parent'}});
    results.push((await resolve(project)).identities.find(value => value.name === 'example.parent'));
  }
  assert.equal(results[0].contentDigest, results[1].contentDigest);
  assert.notEqual(results[0].digest, results[1].digest);
});

test('bundled published path dependencies retain portable locks across consumers and caches', async t => {
  const root = await setup(t), directory = await contract(path.join(root, 'package'), 'example.parent', '1.0.0', {'example.leaf': {version: '^1.0.0', path: 'vendor/leaf'}});
  await contract(path.join(directory, 'vendor/leaf'), 'example.leaf');
  const packed = await packComponent(path.join(directory, 'lawspec.edn'), path.join(root, 'parent.tgz'));
  const bytes = await readFile(packed.file);
  const server = createServer((_, response) => response.end(bytes));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => {server.closeAllConnections(); return new Promise(resolve => server.close(resolve));});
  const specification = {'example.parent': {version: '^1.0.0', archive: `http://127.0.0.1:${server.address().port}/parent.tgz`, sha256: packed.sha256}};
  const first = await consumer(path.join(root, 'first'), specification);
  const original = await resolve(first);
  const embedded = original.lock.packages.find(value => value.name === 'example.leaf');
  assert.equal(embedded.source.kind, 'embedded');
  assert.equal(embedded.source.path, 'vendor/leaf');
  const second = await consumer(path.join(root, 'second'), specification);
  await writeFile(path.join(root, 'second/lawspec.lock.edn'), await readFile(path.join(root, 'first/lawspec.lock.edn')));
  process.env.LAWSPEC_CACHE_DIR = path.join(root, 'second-cache');
  const relocated = await resolve(second, {locked: true});
  assert.deepEqual(relocated.lock, original.lock);
  assert.deepEqual(relocated.identities, original.identities);
  assert.deepEqual((await resolve(second, {locked: true, offline: true})).identities, original.identities);
});

test('published archives cannot follow development path dependencies outside their root', async t => {
  const root = await setup(t), directory = await contract(path.join(root, 'package'), 'example.parent', '1.0.0', {'example.leaf': {version: '^1.0.0', path: '../leaf'}});
  await contract(path.join(root, 'leaf'), 'example.leaf');
  await assert.rejects(packComponent(path.join(directory, 'lawspec.edn'), path.join(root, 'refused.tgz')), /dependency leaves its root/);
  const unsafe = path.join(root, 'unsafe.tgz');
  await tar.c({cwd: directory, file: unsafe, gzip: true}, ['lawspec.edn', 'laws']);
  const bytes = await readFile(unsafe);
  const server = createServer((_, response) => response.end(bytes));
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => {server.closeAllConnections(); return new Promise(resolve => server.close(resolve));});
  const project = await consumer(path.join(root, 'consumer'), {'example.parent': {version: '^1.0.0', archive: `http://127.0.0.1:${server.address().port}/unsafe.tgz`, sha256: contentDigest(bytes)}});
  await assert.rejects(resolve(project), /dependency leaves its downloaded root/);
});

test('immutable cache integrity is checked even when a consumer has no lockfile', async t => {
  const root = await setup(t), repository = await contract(path.join(root, 'git'), 'example.library');
  await exec('git', ['init', '--quiet', repository]);await publish(repository, '1.0.0');
  const project = await consumer(path.join(root, 'consumer'), {'example.library': {version: '^1.0.0', git: repository}});
  const first = await resolve(project), source = first.identities[0].source;
  const {canonical} = await import('../component.mjs');
  const directory = path.join(process.env.LAWSPEC_CACHE_DIR, contentDigest(canonical(source)));
  await writeFile(path.join(directory, 'laws/model.lawspec'), 'unit example.library\nfunction answer (u :: Unit) -> Int32 is 99 end function\nend unit\n');
  await rm(path.join(root, 'consumer/lawspec.lock.edn'));
  await assert.rejects(resolve(project), /Cached contract content changed/);
});

test('concurrent revision resolutions cannot overwrite one another through FETCH_HEAD', async t => {
  const root = await setup(t), repository = await contract(path.join(root, 'git'), 'example.library');
  await exec('git', ['init', '--quiet', repository]);await publish(repository, '1.0.0');
  const warm = await consumer(path.join(root, 'warm'), {'example.library': {version: '^1.0.0', git: repository}});await resolve(warm);
  await contract(repository, 'example.library', '2.0.0');await publish(repository, '2.0.0');
  const projects = await Promise.all(['1.0.0','2.0.0'].map(version=>consumer(path.join(root, version), {'example.library': {version, git: repository, rev: 'v'+version}})));
  const results = await Promise.all(projects.map(project=>resolve(project)));
  assert.deepEqual(results.map(result=>result.packages[0].version), ['1.0.0','2.0.0']);
});
