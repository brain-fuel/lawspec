// Generated from templates/npm/native-host.mjs by lawspec-dev generate. Do not edit.
// Native execution identity is separate from the WebAssembly compiler cache
// and from the solver host. Conservatively bind the executable SDK bundle,
// its installed dependency closure, and the Node binary which runs it.
import {createHash} from 'node:crypto';
import {createRequire} from 'node:module';
import {readFile, readdir, realpath} from 'node:fs/promises';
import {fileURLToPath} from 'node:url';
import path from 'node:path';

const sdkRoot = fileURLToPath(new URL('.', import.meta.url));
// These modules only render explanations, serve editors, create examples or
// execute optional proofs. They do not select or certify native completion.
const separate = new Set([
  'proof.mjs',
  'lsp.mjs',
  'explain.mjs',
  'scalars.mjs',
  'examples-command.mjs',
]);
let nodeIdentityValue;
async function nodeIdentity()
{
  nodeIdentityValue ??= (async () =>
    createHash('sha256')
      .update(await readFile(process.execPath))
      .digest('hex'))();
  return nodeIdentityValue;
}

export async function fingerprintNativeHost(root = sdkRoot)
{
  const hash = createHash('sha256').update('lawspec-native-host-v1\0');
  hash.update(
    JSON.stringify([
      await nodeIdentity(),
      process.version,
      process.platform,
      process.arch,
      process.execArgv,
      process.env.NODE_OPTIONS ?? '',
    ]),
  );
  const add = async (file, label) =>
    hash
      .update(label + '\0')
      .update(await readFile(file))
      .update('\0');
  // New SDK helper modules enter the identity automatically. Project output,
  // declarations, documentation and core.wasm are deliberately outside it.
  for (const entry of (await readdir(root, {withFileTypes: true})).sort(
    (a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0),
  ))
    if (
      entry.isFile() &&
      ((entry.name.endsWith('.mjs') && !separate.has(entry.name)) ||
        entry.name === 'core_jsffi.js')
    )
      await add(path.join(root, entry.name), entry.name);
  for (const entry of (
    await readdir(path.join(root, 'bin'), {withFileTypes: true})
  ).sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0)))
    if (entry.isFile() && entry.name.endsWith('.mjs'))
      await add(path.join(root, 'bin', entry.name), 'bin/' + entry.name);
  const manifest = JSON.parse(
    await readFile(path.join(root, 'package.json'), 'utf8'),
  );
  await add(path.join(root, 'package.json'), 'package.json');
  const seen = new Set();
  async function packageRoot(name, from)
  {
    let directory = path.dirname(
      createRequire(path.join(from, 'package.json')).resolve(name),
    );
    while (true)
    {
      const candidate = path.join(directory, 'package.json');
      const value = await readFile(candidate, 'utf8').then(
        JSON.parse,
        error =>
        {
          if (error.code === 'ENOENT') return null;
          throw error;
        },
      );
      if (value?.name === name)
        return {directory: await realpath(directory), value};
      const parent = path.dirname(directory);
      if (parent === directory)
        throw new Error('Cannot identify native host dependency ' + name);
      directory = parent;
    }
  }
  async function dependency(name, from, optional = false)
  {
    let selected;
    try
    {
      selected = await packageRoot(name, from);
    }
    catch (error)
    {
      if (optional && error.code === 'MODULE_NOT_FOUND')
      {
        hash.update('absent-optional:' + name + '\0');
        return;
      }
      throw error;
    }
    const {directory, value} = selected,
      label = path.relative(root, directory).split(path.sep).join('/');
    hash.update('dependency:' + name + '\0' + label + '\0');
    if (seen.has(directory)) return;
    seen.add(directory);
    async function walk(folder, relative = '')
    {
      for (const entry of (await readdir(folder, {withFileTypes: true})).sort(
        (a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0),
      ))
      {
        const next = relative ? relative + '/' + entry.name : entry.name;
        if (entry.isSymbolicLink())
          throw new Error(
            'Cannot fingerprint symbolic-link content in native host dependency: ' +
              label +
              '/' +
              next,
          );
        if (
          entry.isDirectory() &&
          !['node_modules', '.git'].includes(entry.name)
        )
          await walk(path.join(folder, entry.name), next);
        else if (entry.isFile())
          await add(path.join(folder, entry.name), label + '/' + next);
      }
    }
    await walk(directory);
    for (const child of Object.keys({
      ...value.dependencies,
      ...value.optionalDependencies,
    }).sort())
      await dependency(
        child,
        directory,
        Object.hasOwn(value.optionalDependencies ?? {}, child),
      );
  }
  for (const name of Object.keys({
    ...manifest.dependencies,
    ...manifest.optionalDependencies,
  }).sort())
    await dependency(
      name,
      root,
      Object.hasOwn(manifest.optionalDependencies ?? {}, name),
    );
  return hash.digest('hex');
}

let identity;
export function nativeHostIdentity()
{
  return (identity ??= fingerprintNativeHost());
}
