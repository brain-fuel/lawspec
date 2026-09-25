import { readFile, writeFile, readdir } from "node:fs/promises";
import { createHash } from "node:crypto";
import path from "node:path";
const root = path.resolve(import.meta.dirname, "..");
const hash = (bytes) => createHash("sha256").update(bytes).digest("hex");
async function walk(dir) {
  const out = [];
  for (const e of await readdir(path.join(root, dir), {
    withFileTypes: true,
  })) {
    const p = dir + "/" + e.name;
    if (e.isDirectory()) out.push(...(await walk(p)));
    else if (p.endsWith(".hs")) out.push(p);
  }
  return out;
}
const sourceFiles = [
  ...(await walk("src")),
  ...(await walk("wasm/app")),
  ...(await readdir(path.join(root,"runtime"))).filter(n => !n.startsWith(".") && !n.startsWith("__")).map(n => "runtime/" + n),
  "tools/embed-runtimes.py",
  "package.yaml",
  "stack.yaml",
  "stack.yaml.lock",
  "wasm/cabal.project",
  "wasm/cabal.project.freeze",
  "wasm/lawspec-wasm.cabal",
].sort();
const artifacts = [
  "npm/core.wasm",
  "npm/core_jsffi.js",
  "npm/api.mjs",
  "npm/index.d.ts",
];
const digests = {};
for (const f of [...sourceFiles, ...artifacts])
  digests[f] = hash(await readFile(path.join(root, f)));
if (process.argv.includes("--record"))
  await writeFile(
    path.join(root, "npm/build.json"),
    JSON.stringify(
      { version: 1, compilerSources: sourceFiles, digests },
      null,
      2,
    ) + "\n",
  );
else {
  const record = JSON.parse(
    await readFile(path.join(root, "npm/build.json"), "utf8"),
  );
  if (JSON.stringify(record.compilerSources) !== JSON.stringify(sourceFiles))
    throw new Error("Compiler source set changed; run tools/wasm.sh");
  for (const [file, digest] of Object.entries(digests))
    if (record.digests[file] !== digest)
      throw new Error(
        `Stale build artifact/source: ${file}; run tools/wasm.sh`,
      );
  console.log("WASM, generated API, and compiler source fingerprints match.");
}
