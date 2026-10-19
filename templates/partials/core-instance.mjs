// GHC's JSFFI reactor reads these WASI arguments during initialization. Bound
// the heap below wasm32's address ceiling to enable automatic compaction.
// -with-rtsopts has no effect on this -no-hs-main reactor build.
const coreArguments = ["lawspec", "+RTS", "-M3g", "-RTS"];

// Instantiate the compiler core with a platform's WASI preview1 imports and
// serialize calls: the core handles one JSON request at a time.
async function instantiateCore(module, wasiImports, initialize) {
  const exports = {};
  const jsffi = (await import("./core_jsffi.js")).default;
  const instance = await WebAssembly.instantiate(module, {
    wasi_snapshot_preview1: wasiImports,
    ghc_wasm_jsffi: jsffi(exports),
  });
  Object.assign(exports, instance.exports);
  initialize(instance);
  let pending = Promise.resolve();
  return (input) => {
    const result = pending.then(async () =>
      JSON.parse(await instance.exports.lawspec_call(JSON.stringify(input))),
    );
    // The queue needs completion only, not the previous generated project DTO.
    pending = result.then(() => {}, () => {});
    return result;
  };
}
