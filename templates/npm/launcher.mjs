import { mkdir, readFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import path from "node:path";
let compiled;

//@ partial-core-instance

export async function loadCore() {
  const { WASI } = await import("node:wasi");
  if (Number(process.versions.node.split(".")[0]) < 22)
    throw new Error("LawSpec requires Node 22+");
  compiled ??= readFile(new URL("./core.wasm", import.meta.url)).then(async bytes => ({
    module: await WebAssembly.compile(bytes),
    build: createHash("sha256").update(bytes).digest("hex"),
  }));
  const {module,build}=await compiled;
  let activeRoot, invoke;
  let pending=Promise.resolve();
  const request=async input=>{
    const validCache=typeof input.cacheDirectory==='string';
    let root=validCache&&input.cacheDirectory?path.resolve(input.cacheDirectory):null;
    if(root)try{await mkdir(root,{recursive:true});}catch{root=null;}
    // The requested host directory is an explicit mount, rather than an
    // absolute WASI path accidentally interpreted below cwd. The binary
    // identity separates persisted memos even within one package version.
    if(!invoke||root!==activeRoot){
      const wasi = new WASI({
        version: "preview1", args: coreArguments, env: { PWD: "/" },
        preopens: { "/": process.cwd(), ...(root?{"/lawspec-cache":root}:{}) },
      });
      invoke=await instantiateCore(module,wasi.wasiImport,instance=>wasi.initialize(instance));
      activeRoot=root;
    }
    return invoke({...input,...(validCache?{cacheDirectory:root?`/lawspec-cache/${build}`:undefined}:{})});
  };
  // Cache-root changes are serialized with calls on the active instance.
  return input=>{
    const result=pending.then(()=>request(input));
    pending=result.then(()=>{},()=>{});
    return result;
  };
}
