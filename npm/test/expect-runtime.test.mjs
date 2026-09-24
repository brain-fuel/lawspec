import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, mkdir, writeFile, rm, readFile } from "node:fs/promises";
import path from "node:path";
import { createCompiler } from "../api.mjs";
const exec = promisify(execFile);
// Native integrations install fast-check. Unit CI may not have target packages;
// this test uses a tiny property-registration stub, and executes only the example.
test("generated examples evaluate each asserted expression once without capturing function names", async () => {
  const root = await mkdtemp(path.join(process.cwd(), ".lawspec-runtime-"));
  try {
    const compiler = await createCompiler();
    const result = await compiler.planGeneration({
      target: "javascript",
      sources: [
        {
          path: "once.lawspec",
          content:
            "unit once\nactual :: Int32 -> Int32\nlaw `stable` is definition is `idempotent` actual end example `counts calls` is x = 7 expect actual x = 7 end end",
        },
      ],
    });
    assert.deepEqual(result.diagnostics, []);
    for (const file of result.files) {
      const dest = path.join(root, file.path);
      await mkdir(path.dirname(dest), { recursive: true });
      await writeFile(dest, file.content);
    }
    await mkdir(path.join(root, "node_modules/fast-check"), {
      recursive: true,
    });
    await writeFile(
      path.join(root, "node_modules/fast-check/package.json"),
      JSON.stringify({ type: "module", exports: "./index.js" }),
    );
    await writeFile(
      path.join(root, "node_modules/fast-check/index.js"),
      "export default { integer:()=>null, property:()=>null, assert:()=>{} };",
    );
    await writeFile(
      path.join(root, "src/once.mjs"),
      'let calls=0; export function actual(x){calls++; return x;} process.on("exit",()=>console.log("CALLS="+calls));',
    );
    const env = { ...process.env };
    delete env.NODE_TEST_CONTEXT;
    const output = await exec(
      process.execPath,
      [
        "--test",
        "--test-name-pattern",
        "example: counts calls",
        "test/once.lawspec.test.mjs",
      ],
      { cwd: root, env },
    );
    // One expected-output call, plus f(f(x)) and f(x) for the law equality.
    assert.match(output.stdout, /CALLS=4/);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
