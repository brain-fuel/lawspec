import { readFile } from "node:fs/promises";
let compiled;

//@ partial-core-instance

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
