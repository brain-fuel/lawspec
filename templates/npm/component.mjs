import {toEDNString} from 'edn-data';
import {EDNListParser} from 'edn-data/dist/parse.js';
import {readFile, stat, lstat} from 'node:fs/promises';
import path from 'node:path';
import {createHash} from 'node:crypto';
import {loadCore} from './launcher.mjs';
import {createCompiler} from './api.mjs';
import {collectSources} from './files.mjs';

export const manifestName = 'lawspec.edn';
export const lockName = 'lawspec.lock.edn';
const camel = key => key.replace(/-([a-z])/g, (_, letter) => letter.toUpperCase());
const kebab = key => key.replace(/[A-Z]/g, letter => '-' + letter.toLowerCase());
const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
const fail = (message, file) => {
  const error = new Error(`${file ? file + ': ' : ''}${message}`);
  error.diagnostics = [{code: 'manifest', message, ...(file ? {at: {file, line: 1, column: 1}} : {})}];
  throw error;
};

export function parseManifest(text, file) {
  let values, parser;
  try {
    parser = new EDNListParser();
    values = parser.next('(' + text + '\n)\n');
  } catch (error) { fail(`Invalid EDN: ${error.message}`, file); }
  if (!parser.isDone() || values.length !== 1 || !Array.isArray(values[0]?.map))
    fail('Expected exactly one complete EDN map', file);
  function convert(value) {
    if (value === null || typeof value === 'string' || typeof value === 'boolean') return value;
    if (typeof value === 'number' && Number.isSafeInteger(value)) return value;
    if (Array.isArray(value)) return value.map(convert);
    if (value && typeof value === 'object' && own(value, 'key')) return value.key;
    if (value && typeof value === 'object' && own(value, 'map')) {
      const entries = [], seen = new Set();
      for (const [key, entry] of value.map) {
        if (typeof key !== 'string' && !(key && typeof key.key === 'string'))
          fail('Manifest map keys must be strings or keywords', file);
        const name = typeof key === 'string' ? key : camel(key.key);
        if (seen.has(name)) fail(`Duplicate manifest key: ${name}`, file);
        seen.add(name);
        entries.push([name, convert(entry)]);
      }
      return Object.fromEntries(entries);
    }
    fail('Unsupported manifest EDN value; use maps, vectors, keywords, strings, integers, booleans or nil', file);
  }
  return convert(values[0]);
}

export function writeManifest(value) {
  const identifiers = new Set(['language', 'layers']);
  function convert(value, parent) {
    if (Array.isArray(value)) return value.map(entry => convert(entry, parent));
    if (value && typeof value === 'object') return {map: Object.entries(value).filter(([,entry]) => entry !== undefined).map(([key, entry]) => [
      /^[a-z][A-Za-z0-9]*$/.test(key) ? {key: kebab(key)} : key,
      convert(entry, key),
    ])};
    return typeof value === 'string' && identifiers.has(parent) ? {key: value} : value;
  }
  function layout(value, depth) {
    const indent = '  '.repeat(depth), child = indent + '  ';
    if (value && !Array.isArray(value) && value.map)
      return '{\n' + value.map.map(([key, entry]) => child + toEDNString(key) + ' ' + layout(entry, depth + 1)).join('\n') + '\n' + indent + '}';
    if (Array.isArray(value) && value.some(entry => entry && typeof entry === 'object'))
      return '[\n' + value.map(entry => child + layout(entry, depth + 1)).join('\n') + '\n' + indent + ']';
    return toEDNString(value);
  }
  return layout(convert(value), 0) + '\n';
}

let core;
async function coreRequest(request) {
  core ??= loadCore();
  const result = await (await core)({schemaVersion: 5, ...request});
  if (result.diagnostics?.length) {
    const error = new Error(result.diagnostics.map(item => item.message).join('\n'));
    error.diagnostics = result.diagnostics;
    throw error;
  }
  return result;
}

export async function readManifest(file) {
  if (path.extname(file) !== '.edn') fail('LawSpec component and package manifests must use lawspec.edn; JSON configuration is no longer supported', file);
  const manifest = parseManifest(await readFile(file, 'utf8'), file);
  try { return (await coreRequest({method: 'componentManifest', manifest})).manifest; }
  catch (error) {
    error.message = `${file}: ${error.message}`;
    error.diagnostics = error.diagnostics?.map(item => ({...item, at: {file, line: 1, column: 1}}));
    throw error;
  }
}

export async function findManifest(start = process.cwd()) {
  let directory = path.resolve(start);
  for (;;) {
    const candidate = path.join(directory, manifestName);
    if (await stat(candidate).then(info => info.isFile(), () => false)) return candidate;
    for (const old of ['lawspec.json', 'lawspec-package.json'])
      if (await stat(path.join(directory, old)).then(info => info.isFile(), () => false))
        fail(`${old} is no longer supported; use lawspec.edn`, path.join(directory, old));
    const parent = path.dirname(directory);
    if (parent === directory) fail('No lawspec.edn found in this directory or its parents', start);
    directory = parent;
  }
}

export async function packageVersions(range, versions) {
  return (await coreRequest({method: 'packageVersions', range, versions})).versions;
}

export const dependencyRanges = manifest => Object.fromEntries(Object.entries(manifest.dependencies ?? {}).map(([name, value]) => [name, typeof value === 'string' ? value : value.version]));
export const contentDigest = value => createHash('sha256').update(value).digest('hex');
export function canonical(value) {
  if (Array.isArray(value)) return '[' + value.map(canonical).join(',') + ']';
  if (value && typeof value === 'object') return '{' + Object.keys(value).sort().map(key => JSON.stringify(key) + ':' + canonical(value[key])).join(',') + '}';
  return JSON.stringify(value);
}

export async function componentInput(file, options = {}) {
  const manifest = await readManifest(file), root = path.dirname(path.resolve(file));
  const {resolveDependencies} = await import('./component-packages.mjs');
  const dependencies = await resolveDependencies(file, manifest, options);
  const sources = await collectSources(root, manifest.sources, root);
  return {manifest, root, input: {
    sources, languageProfile: manifest.languageProfile,
    verification: manifest.verification ?? {layers: []},
    ...(manifest.package ? {package: manifest.package} : {}),
    dependencies: dependencyRanges(manifest), packages: dependencies.packages,
    generation: manifest.generation, machineBits: manifest.machineBits ?? 64,
    projectVersion: manifest.component?.version ?? manifest.package?.version,
  }, dependencies};
}

export async function resolveComponent(file, options = {}) {
  const {manifest, root, input, dependencies} = await componentInput(file, options);
  const compiler = await createCompiler();
  const checked = await compiler.check({...input, verification: {layers: []}});
  if (checked.diagnostics?.length) {
    const error = new Error(checked.diagnostics.map(item => item.message).join('\n'));
    error.diagnostics = checked.diagnostics;
    throw error;
  }
  for (const target of manifest.targets ?? []) {
    if (target.nativeBindings === undefined) continue;
    const bound = await compiler.check({...input, verification: {layers: []}, nativeBindings: target.nativeBindings});
    if (bound.diagnostics?.length) {
      const error = new Error(bound.diagnostics.map(item => item.message).join('\n'));
      error.diagnostics = bound.diagnostics;
      throw error;
    }
  }
  const declarations = new Set([
    ...(checked.units ?? []).flatMap(unit => [...(unit.declarations ?? []), ...(unit.abilities ?? [])]).map(item => item.id),
    ...(checked.laws ?? []).map(item => item.id),
  ]);
  const contracts = new Map(Object.entries(dependencies.lock.roots).map(([name,id]) => [name, dependencies.lock.packages.find(item => item.id === id)]));
  if (manifest.package) {
    const {packageDigest} = await import('./component-packages.mjs');
    contracts.set(manifest.package.name, {...manifest.package, digest: await packageDigest(root)});
  }
  for (const [name, requirement] of [...Object.entries(manifest.requires ?? {}), ...(manifest.provides ?? []).map((value, index) => [`provides[${index}]`, value])]) {
    if (!contracts.has(requirement.contract)) fail(`${name}: contract ${requirement.contract} is not resolved`, file);
    for (const declaration of [...(requirement.abilities ?? []), ...(requirement.declarations ?? [])])
      if (!declarations.has(declaration)) fail(`${name}: unknown declaration ${declaration}`, file);
  }
  const identity = {
    manifest,
    sources: input.sources,
    dependencies: dependencies.identities,
    inputs: await fingerprintInputs(root, manifest.inputs ?? []),
  };
  const contractView = value => {
    const selected = contracts.get(value.contract);
    const content = dependencies.identities.find(item => item.name === selected.name && item.version === selected.version);
    return {...value, version: selected.version, digest: content?.digest ?? selected.digest,
      ...(manifest.dependencies?.[value.contract] ? {versionRequirement: typeof manifest.dependencies[value.contract] === 'string' ? manifest.dependencies[value.contract] : manifest.dependencies[value.contract].version} : {})};
  };
  return {
    format: 'lawspec-component', version: 1, manifest: path.resolve(file), root,
    component: manifest.component ?? null, package: manifest.package ?? null,
    fingerprint: contentDigest(canonical(identity)),
    manifestDigest: contentDigest(await readFile(file)),
    targets: manifest.targets ?? [], provides: (manifest.provides ?? []).map(contractView),
    requires: Object.fromEntries(Object.entries(manifest.requires ?? {}).map(([name,value]) => [name, contractView(value)])),
    dependencies: dependencies.identities,
    laws: checked.laws ?? [], declarations: [...declarations].sort(),
  };
}

async function fingerprintInputs(root, inputs) {
  const {readdir} = await import('node:fs/promises');
  const rows = [];
  async function visit(file, relative) {
    const info = await lstat(file);
    if (info.isSymbolicLink()) throw new Error(`Symbolic links are not supported in component inputs: ${relative}`);
    if (info.isDirectory()) {
      for (const entry of (await readdir(file)).sort()) {
        if (['.git', '.lawspec', 'node_modules', 'target', 'bin', 'obj'].includes(entry)) continue;
        await visit(path.join(file, entry), relative + '/' + entry);
      }
    } else if (info.isFile()) rows.push([relative, contentDigest(await readFile(file))]);
  }
  for (const entry of inputs) await visit(path.resolve(root, entry), entry);
  return rows;
}
