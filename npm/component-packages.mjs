// Generated from templates/npm/component-packages.mjs by lawspec-dev generate. Do not edit.
import {readFile, writeFile, mkdir, readdir, lstat, realpath, rename, rm, mkdtemp} from 'node:fs/promises';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {Readable} from 'node:stream';
import {pipeline} from 'node:stream/promises';
import os from 'node:os';
import path from 'node:path';
import * as tar from 'tar';
import {readManifest, parseManifest, writeManifest, manifestName, lockName, packageVersions, dependencyRanges, contentDigest, canonical} from './component.mjs';
import {collectSources, atomicWrite} from './files.mjs';

const exec = promisify(execFile);
const git = async (args, options = {}) => (await exec('git', args, {maxBuffer: 128 * 1024 * 1024, ...options})).stdout;
const optional = async file => readFile(file, 'utf8').catch(error => {if (error.code === 'ENOENT') return null; throw error;});
const inside = (root, file) => file === root || file.startsWith(root + path.sep);
const rangeOf = value => typeof value === 'string' ? value : value.version;

function validateLock(lock) {
  const map = value => value && typeof value === 'object' && !Array.isArray(value);
  const invalid = () => {throw new Error('Invalid LawSpec lockfile; regenerate it with lawspec fetch');};
  if (!map(lock) || lock.format !== 'lawspec-lock' || lock.version !== 1 ||
      !map(lock.roots) || !map(lock.selections) || !Array.isArray(lock.packages)) invalid();
  const ids = new Set();
  for (const entry of lock.packages) {
    if (!map(entry) || typeof entry.id !== 'string' || ids.has(entry.id) ||
        typeof entry.name !== 'string' || typeof entry.version !== 'string' ||
        !map(entry.dependencies) || !map(entry.source)) invalid();
    ids.add(entry.id);
    const source = entry.source;
    if (source.kind === 'path') {if (typeof source.path !== 'string') invalid();}
    else if (['git', 'archive'].includes(source.kind)) {
      if (typeof source.url !== 'string' || !/^[a-f0-9]{64}$/.test(entry.digest)) invalid();
      if (source.kind === 'git' && !/^[a-f0-9]{40,64}$/.test(source.commit)) invalid();
      if (source.kind === 'archive' && !/^[a-f0-9]{64}$/.test(source.sha256)) invalid();
    } else invalid();
  }
  for (const selection of Object.values(lock.selections))
    if (!map(selection) || !Object.hasOwn(selection, 'request') || !ids.has(selection.package)) invalid();
  for (const id of [...Object.values(lock.roots), ...lock.packages.flatMap(entry => Object.values(entry.dependencies))])
    if (!ids.has(id)) invalid();
}

async function filesUnder(root) {
  const files = [];
  async function walk(file, relative) {
    const info = await lstat(file);
    if (info.isSymbolicLink()) throw new Error(`Contract packages cannot contain symbolic links: ${relative}`);
    if (info.isDirectory()) {
      for (const name of (await readdir(file)).sort()) {
        if (['.git', '.lawspec', 'node_modules', 'target', 'bin', 'obj'].includes(name)) continue;
        await walk(path.join(file, name), relative ? `${relative}/${name}` : name);
      }
    } else if (info.isFile()) files.push(relative);
  }
  await walk(root, '');
  return files;
}

export async function packageDigest(root) {
  const manifest = await readManifest(path.join(root, manifestName));
  const files = await packageFiles(root, manifest);
  return contentDigest(canonical(await Promise.all(files.map(async file => [file, contentDigest(await readFile(path.join(root, file)))]))));
}

async function packageFiles(root, manifest) {
  const selected = new Set([manifestName]);
  const realRoot = await realpath(root);
  for (const entry of [...manifest.sources, ...(manifest.assets ?? [])]) {
    const location = path.resolve(root, entry);
    if (!inside(root, location) || !inside(realRoot, await realpath(location)))
      throw new Error(`Published package path leaves its root: ${entry}`);
    await filesUnder(location);
  }
  const sources = await collectSources(root, manifest.sources, root);
  for (const source of sources) {
    if (!inside(root, path.resolve(root, source.path))) throw new Error(`Published package source leaves its root: ${source.path}`);
    selected.add(source.path);
  }
  for (const entry of manifest.assets ?? []) {
    const location = path.resolve(root, entry);
    if (!inside(root, location)) throw new Error(`Published package asset leaves its root: ${entry}`);
    const info = await lstat(location);
    if (info.isSymbolicLink()) throw new Error(`Published package asset is a symbolic link: ${entry}`);
    if (info.isDirectory()) for (const nested of await filesUnder(location)) selected.add(path.relative(root, path.join(location, nested)));
    else selected.add(entry);
  }
  return [...selected].sort();
}

async function unpack(bytes, directory) {
  await mkdir(directory, {recursive: true});
  let refused;
  await pipeline(Readable.from([bytes]), tar.x({cwd: directory, strict: true, preservePaths: false, filter(name, entry) {
    const normalized = path.resolve(directory, name);
    if (path.isAbsolute(name) || name.split(/[\\/]/).includes('..') || !inside(directory, normalized) || !['File', 'Directory', 'OldFile', 'ContiguousFile'].includes(entry.type)) {
      refused = `Unsafe package archive entry: ${name}`;
      return false;
    }
    return true;
  }}));
  if (refused) throw new Error(refused);
}

export async function resolveDependencies(file, manifest, options = {}) {
  const root = path.dirname(path.resolve(file));
  const cache = path.resolve(process.env.LAWSPEC_CACHE_DIR ?? path.join(process.env.XDG_CACHE_HOME ?? path.join(os.homedir(), '.cache'), 'lawspec', 'packages'));
  const locked = !!options.locked, offline = !!options.offline || process.env.LAWSPEC_OFFLINE === '1';
  const previousText = await optional(path.join(root, lockName));
  const previous = previousText === null ? null : parseManifest(previousText, path.join(root, lockName));
  if (previous) validateLock(previous);
  const oldSelections = previous?.selections ?? {}, selections = {}, entries = new Map(), packages = new Map(), identities = new Map();
  const local = new Map(), localSeen = new Set();

  async function localCandidates(directory, owner) {
    for (const name of owner.packages ?? []) {
      const location = path.resolve(directory, name);
      if (localSeen.has(location)) continue;
      localSeen.add(location);
      const candidate = await readManifest(path.join(location, manifestName));
      if (!candidate.package) throw new Error(`${location}: expected a package identity`);
      const list = local.get(candidate.package.name) ?? [];
      list.push({directory: location, manifest: candidate});
      local.set(candidate.package.name, list);
      await localCandidates(location, candidate);
    }
  }
  await localCandidates(root, manifest);

  async function gitCheckout(source) {
    const repository = path.join(cache, 'git', contentDigest(source.url));
    await mkdir(repository, {recursive: true});
    if (await optional(path.join(repository, 'HEAD')) === null) await git(['init', '--bare', '--quiet', repository]);
    const present = await git(['--git-dir', repository, 'cat-file', '-e', `${source.commit}^{commit}`]).then(() => true, () => false);
    if (!present) {
      if (offline) throw new Error(`Offline: Git revision ${source.commit} is not cached`);
      await git(['--git-dir', repository, 'fetch', '--quiet', '--no-tags', source.url, source.commit]);
    }
    return git(['--git-dir', repository, 'archive', '--format=tar', source.subdir ? `${source.commit}:${source.subdir}` : source.commit], {encoding: 'buffer'});
  }

  async function downloaded(source, known) {
    const id = contentDigest(canonical(source)), directory = path.join(cache, id);
    if (await optional(path.join(directory, manifestName)) !== null) {
      if (known && await packageDigest(directory) !== known.digest) throw new Error(`Cached contract content changed: ${known.name} ${known.version}`);
      return {directory, source};
    }
    if (offline && source.kind === 'archive') throw new Error(`Offline: ${source.url} is not cached`);
    let bytes;
    if (source.kind === 'git') bytes = await gitCheckout(source);
    else {
      const url = new URL(source.url);
      if (url.protocol !== 'https:' && !(url.protocol === 'http:' && ['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)))
        throw new Error('Contract archives must use HTTPS');
      const answer = await fetch(url);
      if (!answer.ok) throw new Error(`Contract download failed: HTTP ${answer.status} for ${url}`);
      bytes = Buffer.from(await answer.arrayBuffer());
      if (contentDigest(bytes) !== source.sha256) throw new Error(`Contract archive SHA-256 mismatch: ${url}`);
    }
    await mkdir(cache, {recursive: true});
    const temporary = await mkdtemp(path.join(cache, '.unpack-'));
    try {
      await unpack(bytes, temporary);
      await readManifest(path.join(temporary, manifestName));
      try { await rename(temporary, directory); }
      catch (error) { if (!['EEXIST', 'ENOTEMPTY'].includes(error.code)) throw error; }
    } finally { await rm(temporary, {recursive: true, force: true}); }
    if (known && await packageDigest(directory) !== known.digest) throw new Error(`Downloaded contract content differs from lock: ${known.name}`);
    return {directory, source};
  }

  async function materialize(name, specification, directory, old) {
    const refresh = options.update === true || options.update === name;
    if (old && !refresh && canonical(old.request) === canonical(specification)) {
      const entry = previous.packages.find(item => item.id === old.package);
      if (!entry) throw new Error(`Lockfile references missing package ${old.package}`);
      if (entry.source.kind === 'path') return {directory: path.resolve(root, entry.source.path), source: entry.source};
      return downloaded(entry.source, entry);
    }
    if (locked) throw new Error(`Lockfile must change for ${name}; run lawspec fetch without --locked`);
    if (typeof specification === 'string') {
      const candidates = local.get(name) ?? [];
      const accepted = await packageVersions(specification, candidates.map(item => item.manifest.package.version));
      const chosen = candidates.find(item => item.manifest.package.version === accepted[0]);
      if (!chosen) throw new Error(`requires ${name} ${specification}, but ${candidates.length === 1 ? 'version ' + candidates[0].manifest.package.version + ' is supplied' : 'no supplied version satisfies it'}`);
      return {directory: chosen.directory, source: {kind: 'path', path: path.relative(root, chosen.directory) || '.'}};
    }
    if (specification.path) {
      const location = path.resolve(directory, specification.path);
      return {directory: location, source: {kind: 'path', path: path.relative(root, location) || '.'}};
    }
    if (specification.archive) return downloaded({kind: 'archive', url: specification.archive, sha256: specification.sha256});
    if (offline) throw new Error(`Offline: resolving ${name} requires a lockfile`);
    let ref = specification.rev, tagVersion;
    if (!ref) {
      const prefix = specification.tagPrefix ?? 'v';
      const tags = (await git(['ls-remote', '--tags', '--refs', '--', specification.git])).trim().split('\n').filter(Boolean).map(line => {
        const [commit, tag] = line.split(/\s+/);
        return {commit, tag: tag.replace('refs/tags/', '')};
      }).filter(item => item.tag.startsWith(prefix) && /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(item.tag.slice(prefix.length)));
      const versions = await packageVersions(specification.version, tags.map(item => item.tag.slice(prefix.length)));
      const chosen = tags.find(item => item.tag.slice(prefix.length) === versions[0]);
      if (!chosen) throw new Error(`No published Git version satisfies ${name} ${specification.version}`);
      ref = chosen.commit;
      tagVersion = chosen.tag.slice(prefix.length);
    }
    const repository = path.join(cache, 'git', contentDigest(specification.git));
    await mkdir(repository, {recursive: true});
    if (await optional(path.join(repository, 'HEAD')) === null) await git(['init', '--bare', '--quiet', repository]);
    await git(['--git-dir', repository, 'fetch', '--quiet', '--no-tags', specification.git, ref]);
    const commit = (await git(['--git-dir', repository, 'rev-parse', 'FETCH_HEAD^{commit}'])).trim();
    return downloaded({kind: 'git', url: specification.git, commit, ...(tagVersion ? {tagVersion} : {}), ...(specification.subdir ? {subdir: specification.subdir} : {})});
  }

  async function resolve(name, specification, directory, owner, ancestry) {
    const key = owner + '::' + name, old = oldSelections[key];
    const loaded = await materialize(name, specification, directory, old);
    const described = await readManifest(path.join(loaded.directory, manifestName));
    if (!described.package || described.package.name !== name) throw new Error(`Dependency ${name} has a different package identity`);
    const version = described.package.version;
    if (loaded.source.tagVersion && loaded.source.tagVersion !== version)
      throw new Error(`Git tag version ${loaded.source.tagVersion} differs from ${name} manifest version ${version}`);
    if (!(await packageVersions(rangeOf(specification), [version])).length) throw new Error(`requires ${name} ${rangeOf(specification)}, but version ${version} is supplied`);
    const id = contentDigest(canonical({name, version, source: loaded.source}));
    selections[key] = {request: specification, package: id};
    if (ancestry.includes(id)) throw new Error(`Package dependency cycle: ${[...ancestry, id].join(' -> ')}`);
    if (entries.has(id)) return id;
    const digest = await packageDigest(loaded.directory), identity = {name, version, source: loaded.source, digest};
    const sameVersion = [...identities.values()].find(item => item.name === name && item.version === version);
    if (sameVersion && sameVersion.digest !== digest) throw new Error(`Ambiguous content for ${name} ${version}`);
    const entry = {id, name, version, source: loaded.source, ...(loaded.source.kind === 'path' ? {} : {digest}), dependencies: {}};
    entries.set(id, entry);
    identities.set(id, identity);
    await localCandidates(loaded.directory, described);
    for (const [dependency, child] of Object.entries(described.dependencies ?? {}).sort())
      entry.dependencies[dependency] = await resolve(dependency, child, loaded.directory, id, [...ancestry, id]);
    packages.set(id, {name, version, dependencies: dependencyRanges(described), sources: await collectSources(loaded.directory, described.sources, root)});
    return id;
  }
  const roots = {};
  for (const [name, specification] of Object.entries(manifest.dependencies ?? {}).sort())
    roots[name] = await resolve(name, specification, root, '$', []);
  const lock = {format: 'lawspec-lock', version: 1, roots, selections, packages: [...entries.values()].sort((a,b) => a.id.localeCompare(b.id))};
  if (entries.size || previous) {
    if (locked && canonical(lock) !== canonical(previous)) throw new Error('Lockfile is out of date; run lawspec fetch');
    if (!locked && canonical(lock) !== canonical(previous)) await atomicWrite(path.join(root, lockName), writeManifest(lock));
  }
  const ordered = values => [...values].sort((a,b) => a.name.localeCompare(b.name) || a.version.localeCompare(b.version));
  return {packages: ordered(packages.values()), identities: ordered(identities.values()), lock};
}

export async function packComponent(file, output) {
  if (path.basename(file) !== manifestName) throw new Error('Published packages require the canonical lawspec.edn filename');
  const manifest = await readManifest(file), root = path.dirname(path.resolve(file));
  if (!manifest.package) throw new Error('lawspec package --output requires a package identity');
  const selected = await packageFiles(root, manifest);
  await mkdir(path.dirname(path.resolve(output)), {recursive: true});
  await tar.c({cwd: root, file: path.resolve(output), gzip: true, portable: true, mtime: new Date(0), noDirRecurse: true}, selected);
  return {file: path.resolve(output), sha256: contentDigest(await readFile(output)), package: manifest.package};
}
