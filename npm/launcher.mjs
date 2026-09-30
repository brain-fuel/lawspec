// Generated from templates/npm/launcher.mjs by lawspec-dev generate. Do not edit.
import { readFile } from "node:fs/promises";
let compiled;

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
    pending = result.catch(() => {});
    return result;
  };
}

export async function loadCore() {
  const { WASI } = await import("node:wasi");
  if (Number(process.versions.node.split(".")[0]) < 22)
    throw new Error("LawSpec requires Node 22+");
  compiled ??= readFile(new URL("./core.wasm", import.meta.url)).then(
    WebAssembly.compile,
  );
  const wasi = new WASI({
    version: "preview1",
    args: ["lawspec"],
    env: { PWD: "/" },
    preopens: { "/": process.cwd() },
  });
  return instantiateCore(await compiled, wasi.wasiImport, (instance) =>
    wasi.initialize(instance),
  );
}
