import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile, rm, readdir } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { supported, doctor } from "../doctor.mjs";
const exec = promisify(execFile);
test("compatibility profiles enforce Java 25 and Python 3.13 floors", () => {
  assert.equal(supported("java", "java", "24.0.2"), false);
  assert.equal(supported("java", "java", "25.0.4"), true);
  assert.equal(supported("python", "python", "3.12.12"), false);
  assert.equal(supported("python", "python", "3.13.15"), true);
  assert.equal(supported("python", "python", "3.13.0rc1"), false);
  assert.equal(supported("python", "hypothesis", "6.0.0"), false);
});
test("incompatible or unverifiable environments prevent generation writes", async (t) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "lawspec-doctor-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  const executable = path.join(root, "python");
  const config = {
    version: 1,
    sources: ["codec.lawspec"],
    targets: [{ language: "python", root: ".", python: executable }],
  };
  await writeFile(path.join(root, "lawspec.json"), JSON.stringify(config));
  await writeFile(
    path.join(root, "codec.lawspec"),
    await readFile(new URL("../starter.lawspec", import.meta.url), "utf8"),
  );
  for (const version of ["3.12.15", "unknown"]) {
    const report = {
      python: version,
      pytest: "8.4.2",
      hypothesis: "6.135.26",
      config: { pythonpath: ["src"], testpaths: ["tests"] },
    };
    await writeFile(
      executable,
      `#!${process.execPath}\nconsole.log(${JSON.stringify(JSON.stringify(report))});\n`,
      { mode: 0o755 },
    );
    const before = (await readdir(root)).sort();
    assert.equal((await doctor(config.targets[0], root)).ok, false);
    await assert.rejects(
      exec(
        process.execPath,
        [new URL("../bin/lawspec.mjs", import.meta.url).pathname, "generate"],
        { cwd: root },
      ),
      (e) => e.code === 1,
    );
    assert.deepEqual((await readdir(root)).sort(), before);
    assert.equal(
      await readFile(path.join(root, "lawspec.json"), "utf8"),
      JSON.stringify(config),
    );
  }
});
