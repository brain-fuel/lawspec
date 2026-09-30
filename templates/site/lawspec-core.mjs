// The LawSpec compiler in the browser. core.wasm and core_jsffi.js sit beside
// this module. The compiler core is pure: it reads no files and needs no
// clock beyond startup, so a minimal WASI preview1 shim suffices.

//@ partial-core-instance

const ERRNO_SUCCESS = 0;
const ERRNO_BADF = 8;
const ERRNO_NOENT = 44;
const ERRNO_NOSYS = 52;

class ExitError extends Error {
  constructor(code) {
    super(`LawSpec core exited with status ${code}`);
    this.code = code;
  }
}

// Arguments and environment are fixed; standard output and error go to the
// console; there are no preopened directories, so every path fails.
function wasiImports(memory) {
  const view = () => new DataView(memory().buffer);
  const bytes = () => new Uint8Array(memory().buffer);
  const encoder = new TextEncoder();
  const args = ["lawspec"].map((a) => encoder.encode(a + "\0"));
  const environment = [];
  const strings = (list) => ({
    sizes(countOut, sizeOut) {
      view().setUint32(countOut, list.length, true);
      view().setUint32(sizeOut, list.reduce((n, s) => n + s.length, 0), true);
      return ERRNO_SUCCESS;
    },
    get(pointers, buffer) {
      let offset = buffer;
      list.forEach((s, i) => {
        view().setUint32(pointers + 4 * i, offset, true);
        bytes().set(s, offset);
        offset += s.length;
      });
      return ERRNO_SUCCESS;
    },
  });
  const argv = strings(args);
  const environ = strings(environment);
  const decoders = { 1: new TextDecoder(), 2: new TextDecoder() };
  const lines = { 1: "", 2: "" };
  const known = {
    args_sizes_get: argv.sizes,
    args_get: argv.get,
    environ_sizes_get: environ.sizes,
    environ_get: environ.get,
    clock_time_get(_id, _precision, out) {
      const nanoseconds = BigInt(Math.round(performance.now() * 1e6)) + 1_700_000_000_000_000_000n;
      view().setBigUint64(out, nanoseconds, true);
      return ERRNO_SUCCESS;
    },
    clock_res_get(_id, out) {
      view().setBigUint64(out, 1000n, true);
      return ERRNO_SUCCESS;
    },
    random_get(buffer, length) {
      crypto.getRandomValues(bytes().subarray(buffer, buffer + length));
      return ERRNO_SUCCESS;
    },
    fd_write(fd, iovs, count, writtenOut) {
      if (fd !== 1 && fd !== 2) return ERRNO_BADF;
      let written = 0;
      for (let i = 0; i < count; i++) {
        const pointer = view().getUint32(iovs + 8 * i, true);
        const length = view().getUint32(iovs + 8 * i + 4, true);
        lines[fd] += decoders[fd].decode(bytes().subarray(pointer, pointer + length), { stream: true });
        written += length;
      }
      const parts = lines[fd].split("\n");
      lines[fd] = parts.pop();
      for (const line of parts) (fd === 1 ? console.log : console.error)(line);
      view().setUint32(writtenOut, written, true);
      return ERRNO_SUCCESS;
    },
    fd_fdstat_get(fd, out) {
      if (fd > 2) return ERRNO_BADF;
      bytes().fill(0, out, out + 24);
      view().setUint8(out, 2); // character device
      return ERRNO_SUCCESS;
    },
    fd_prestat_get: () => ERRNO_BADF,
    fd_close: () => ERRNO_SUCCESS,
    proc_exit(code) {
      throw new ExitError(code);
    },
    sched_yield: () => ERRNO_SUCCESS,
  };
  return new Proxy(known, {
    get(target, name) {
      if (name in target) return target[name];
      if (typeof name === "string" && name.startsWith("path_")) return () => ERRNO_NOENT;
      return () => ERRNO_NOSYS;
    },
  });
}

let compiled;

// url: where core.wasm is served; defaults to beside this module.
export async function loadCore(url = new URL("./core.wasm", import.meta.url)) {
  compiled ??= (async () => {
    const response = await fetch(url);
    if (!response.ok) throw new Error(`Cannot load ${url}: ${response.status}`);
    return WebAssembly.compileStreaming
      ? WebAssembly.compileStreaming(response).catch(async () => WebAssembly.compile(await (await fetch(url)).arrayBuffer()))
      : WebAssembly.compile(await response.arrayBuffer());
  })();
  const module = await compiled;
  let memory;
  // Imports are fixed up front by name; the memory is known once instantiated.
  const imports = {};
  for (const entry of WebAssembly.Module.imports(module))
    if (entry.module === "wasi_snapshot_preview1") imports[entry.name] = (...args) => shim[entry.name](...args);
  const shim = wasiImports(() => memory);
  return instantiateCore(module, imports, (instance) => {
    memory = instance.exports.memory;
    instance.exports._initialize();
  });
}

export async function createCompiler(url) {
  const call = await loadCore(url);
  const request = (method) => (input) =>
    call({ schemaVersion: input.nativeBindings === undefined ? 3 : 4, ...input, method });
  return { check: request("check"), expand: request("expand"), planGeneration: request("planGeneration") };
}
