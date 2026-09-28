import { execFileSync } from "node:child_process";
import { readFile, readdir } from "node:fs/promises";
import assert from "node:assert/strict";
import path from "node:path";
import { createCompiler } from "../npm/api.mjs";
const root = path.resolve(import.meta.dirname, "..");
const bin = process.env.LAWSPEC_CORE || path.join(
  execFileSync("stack", ["path", "--local-install-root"], {
    cwd: root,
    encoding: "utf8",
  }).trim(),
  "bin/lawspec-core",
);
const content = await readFile(
  path.join(root, "examples/specs/atoi_codec.lawspec"),
  "utf8",
);
const compiler = await createCompiler();
const requested = process.argv.slice(2);
const fixturePaths = requested.length ? requested.map(name => path.resolve(name)) :
  (await readdir(path.join(root, "examples/specs")))
    .filter(name => name.endsWith(".lawspec"))
    .sort()
    .map(name => path.join(root, "examples/specs", name));
const fixtures = [
  ...(await Promise.all(fixturePaths.map(name => readFile(name, "utf8")))),
  content.replace("x = -42", "x = 2147483648"),
  content.replace("representing an Int32", "λ 日本語 😀 representing an Int32"),
];
async function compare(method, input, label) {
  const native = JSON.parse(
    execFileSync(bin, [], {
      input: JSON.stringify({ ...input, method }),
      maxBuffer: 64 * 1024 * 1024,
      encoding: "utf8",
    }),
  );
  assert.deepEqual(await compiler[method](input), native, label);
}
for (const machineBits of [32, 64]) {
  for (const [index, text] of fixtures.entries()) {
    const input = {sources: [{path: "fixture.lawspec", content: text}], machineBits};
    for (const method of ["check", "expand"])
      await compare(method, input, `${method}: fixture ${index}, ${machineBits} bits`);
  }
  console.log(`Check/expand parity passed for ${fixtures.length} fixtures at ${machineBits} bits.`);
}
for (const machineBits of [32,64])
for (const minify of [false, true]) {
for (const [index, text] of fixtures.entries())
  for (const target of [
    "java",
    "python",
    "javascript",
    "typescript",
    "go",
    "haskell",
    "kotlin",
    "rust",
  ]) {
    const input = {
      sources: [{ path: "codec.lawspec", content: text }],
      target,
      machineBits,
      minify,
    };
    await compare("planGeneration", input,
      `fixture ${index}, ${target}, ${machineBits} bits, minify=${minify}`);
  }
console.log(`Generation parity passed at ${machineBits} bits, minify=${minify}.`);
}
console.log(
  `Native/WASM parity: ${fixtures.length * 32} fixture/target/width/layout combinations passed.`,
);
