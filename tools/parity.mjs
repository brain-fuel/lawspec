import { execFileSync } from "node:child_process";
import { readFile } from "node:fs/promises";
import assert from "node:assert/strict";
import path from "node:path";
import { createCompiler } from "../npm/api.mjs";
const root = path.resolve(import.meta.dirname, "..");
const bin = path.join(
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
const fixtures = [
  ...(await Promise.all(
    [
      "refinements",
      "scalars",
      "scalar_catalog",
      "scalar_adapters",
      "slug",
      "canonical_url",
      "mixed_inputs",
      "parse_port",
      "boolean_flags",
      "algebra",
      "currying",
    ].map((name) =>
      readFile(path.join(root, `examples/specs/${name}.lawspec`), "utf8"),
    ),
  )),
  await readFile(path.join(root, "examples/specs/equivalent.lawspec"), "utf8"),
  content,
  content.replace("x = -42", "x = 2147483648"),
  content.replace("representing an Int32", "λ 日本語 😀 representing an Int32"),
];
for (const machineBits of [32,64])
for (const text of fixtures)
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
    };
    const native = JSON.parse(
      execFileSync(bin, [], {
        input: JSON.stringify({ ...input, method: "planGeneration" }),
        maxBuffer: 64 * 1024 * 1024,
        encoding: "utf8",
      }),
    );
    assert.deepEqual(await compiler.planGeneration(input), native);
  }
console.log(
  `Native/WASM parity: ${fixtures.length * 16} fixture/target combinations passed.`,
);
