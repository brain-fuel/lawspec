import { readFile } from "node:fs/promises";
let compiled;
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
  const exports = {};
  const jsffi = (await import("./core_jsffi.js")).default;
  const instance = await WebAssembly.instantiate(await compiled, {
    wasi_snapshot_preview1: wasi.wasiImport,
    ghc_wasm_jsffi: jsffi(exports),
  });
  Object.assign(exports, instance.exports);
  wasi.initialize(instance);
  let pending = Promise.resolve();
  return (input) => {
    const result = pending.then(async () =>
      JSON.parse(await instance.exports.lawspec_call(JSON.stringify(input))),
    );
    pending = result.catch(() => {});
    return result;
  };
}
