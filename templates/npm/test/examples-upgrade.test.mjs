import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, readFile, writeFile, rm, symlink } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
const exec = promisify(execFile);
const cli = new URL("../bin/lawspec.mjs", import.meta.url).pathname;
const exported = async (root, args = []) =>
  JSON.parse((await exec(process.execPath, [cli, "examples", "--json", ...args], {
    cwd: root, maxBuffer: 16 * 1024 * 1024,
  })).stdout);
const withRoot = async (work) => {
  const root = await mkdtemp(path.join(os.tmpdir(), "lawspec-examples-"));
  try {
    await work(root);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
};
// Each case exports one target into a folder of its own, so the cases run
// at once. The export of every target is in examples.test.mjs.
describe("examples on one target", { concurrency: true }, () => {
it("upgrades a 0.4 Kotlin adapter while preserving its implementation", () => withRoot(async (root) => {
  const [kotlin] = await exported(root, ["--target", "kotlin"]);
  const kotlinAdapter = "src/main/kotlin/example/BooleanFlags.kt";
  const legacy = "package example\nfun flipFlag(x: Boolean): Boolean = !x\n";
  await writeFile(path.join(kotlin.directory, kotlinAdapter), legacy);
  const manifestPath = path.join(kotlin.directory, ".lawspec/generated.json");
  const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
  manifest.adapters[kotlinAdapter] = "previous-stub-shape";
  await writeFile(manifestPath, JSON.stringify(manifest));
  const updated = await exec(
    process.execPath,
    [cli, "examples", "--target", "kotlin"],
    { cwd: root },
  );
  assert.match(updated.stdout, /Review required adapter signatures/);
  assert.match(updated.stdout, /object BooleanFlags/);
  assert.equal(
    await readFile(path.join(kotlin.directory, kotlinAdapter), "utf8"),
    legacy,
  );
}));

it("preserves an implemented adapter and protects an edited test", () => withRoot(async (root) => {
  const [java] = await exported(root, ["--target", "java"]);
  const adapter = path.join(
    java.directory,
    "src/main/java/example/Slug.java",
  );
  await writeFile(adapter, "// user implementation\n");
  const again = await exported(root, ["--target", "java"]);
  assert.ok(again.every((t) => t.changes === 0));
  assert.equal(await readFile(adapter, "utf8"), "// user implementation\n");
  const test = path.join(
    java.directory,
    "src/test/java/example/SlugLawSpecTest.java",
  );
  await writeFile(test, "// user edit\n");
  await assert.rejects(exported(root, ["--target", "java"]));
  assert.equal(await readFile(test, "utf8"), "// user edit\n");
}));

it("exports one target to a chosen folder and rejects unsafe paths and unknown targets", () => withRoot(async (root) => {
  const single = await exported(root, ["--target", "python", "--output", "custom"]);
  assert.equal(single.length, 1);
  await assert.rejects(exported(root, ["--output", "../escape"]));
  await symlink(root, path.join(root, "linked"));
  await assert.rejects(exported(root, ["--output", "linked"]));
  await assert.rejects(exported(root, ["--target", "unknown"]));
}));
});
