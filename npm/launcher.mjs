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
  // node:wasi imports are V8 fast API calls. uvwasi allocates inside them
  // (path_open while reading a warm cache), which can start a collection that
  // cannot walk the optimized caller's frame: Node segfaults on Linux x64.
  // Ordinary calls keep the same results. ref:DEC-s1j-shared-failures
  (await import('node:v8')).setFlagsFromString('--no-turbo-fast-api-calls');
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
    let unusable = null;
    if (root)
      try
      {
        await mkdir(root, {recursive: true});
      }
      catch (error)
      {
        unusable = {path: root, reason: error.message};
        root = null;
      }
    // The requested host directory is an explicit mount, rather than an
    // absolute WASI path accidentally interpreted below cwd. A mount is fixed
    // when an instance starts, so only a request that names another
    // directory starts a new one: a request that names none runs on the
    // instance there is, without a cache, and keeps what it holds in memory.
    if (!invoke || (root && root !== activeRoot))
    {
      const trace = process.env.LAWSPEC_CACHE_TRACE;
      const wasi = new WASI({
        version: 'preview1',
        args: coreArguments,
        env: {PWD: '/', ...(trace ? {LAWSPEC_CACHE_TRACE: trace} : {})},
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
    // The binary's identity separates persisted memos even within one
    // package version. Sixteen characters keep the path short for Windows.
    const result = await invoke({
      ...input,
      ...(validCache
        ? {
            cacheDirectory: root
              ? `/lawspec-cache/${build.slice(0, 16)}`
              : undefined,
          }
        : {}),
    });
    // The compiler names an entry it could not store by its mounted path.
    if (result?.cacheFailure && root)
      result.cacheFailure.path = path.join(
        root,
        ...result.cacheFailure.path.split('/').slice(2),
      );
    if (unusable && result && typeof result === 'object')
      result.cacheFailure = unusable;
    return result;
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
