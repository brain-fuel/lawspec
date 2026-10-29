// Generated from templates/npm/launcher.mjs by lawspec-dev generate. Do not edit.
import {mkdir, readFile} from 'node:fs/promises';
import {createHash} from 'node:crypto';
import path from 'node:path';
let compiled;

// GHC's JSFFI reactor reads these WASI arguments during initialization. Bound
// the heap below wasm32's address ceiling and compact the oldest generation
// in place instead of reserving a second copy near that ceiling.
// -with-rtsopts has no effect on this -no-hs-main reactor build.
const coreArguments = ['lawspec', '+RTS', '-M3584m', '-c', '-RTS'];

// Instantiate the compiler core with a platform's WASI preview1 imports and
// serialize calls: the core handles one JSON request at a time.
async function instantiateCore(module, wasiImports, initialize)
{
  const exports = {};
  const jsffi = (await import('./core_jsffi.js')).default;
  const instance = await WebAssembly.instantiate(module, {
    wasi_snapshot_preview1: wasiImports,
    ghc_wasm_jsffi: jsffi(exports),
  });
  Object.assign(exports, instance.exports);
  initialize(instance);
  let pending = Promise.resolve();
  return input =>
  {
    const result = pending.then(async () =>
      JSON.parse(await instance.exports.lawspec_call(JSON.stringify(input))),
    );
    // The queue needs completion only, not the previous generated project DTO.
    pending = result.then(
      () =>
      {},
      () =>
      {},
    );
    return result;
  };
}

export async function loadCore()
{
  const {WASI} = await import('node:wasi');
  if (Number(process.versions.node.split('.')[0]) < 22)
    throw new Error('LawSpec requires Node 22+');
  compiled ??= readFile(new URL('./core.wasm', import.meta.url)).then(
    async bytes => ({
      module: await WebAssembly.compile(bytes),
      build: createHash('sha256').update(bytes).digest('hex'),
    }),
  );
  const {module, build} = await compiled;
  let activeRoot, invoke;
  let pending = Promise.resolve();
  const request = async input =>
  {
    const validCache = typeof input.cacheDirectory === 'string';
    let root =
      validCache && input.cacheDirectory
        ? path.resolve(input.cacheDirectory)
        : null;
    if (root)
      try
      {
        await mkdir(root, {recursive: true});
      }
      catch
      {
        root = null;
      }
    // The requested host directory is an explicit mount, rather than an
    // absolute WASI path accidentally interpreted below cwd. The binary
    // identity separates persisted memos even within one package version.
    if (!invoke || root !== activeRoot)
    {
      const wasi = new WASI({
        version: 'preview1',
        args: coreArguments,
        env: {PWD: '/'},
        preopens: {
          '/': process.cwd(),
          ...(root ? {'/lawspec-cache': root} : {}),
        },
      });
      invoke = await instantiateCore(module, wasi.wasiImport, instance =>
        wasi.initialize(instance),
      );
      activeRoot = root;
    }
    return invoke({
      ...input,
      ...(validCache
        ? {cacheDirectory: root ? `/lawspec-cache/${build}` : undefined}
        : {}),
    });
  };
  // Cache-root changes are serialized with calls on the active instance.
  return input =>
  {
    const result = pending.then(() => request(input));
    pending = result.then(
      () =>
      {},
      () =>
      {},
    );
    return result;
  };
}
