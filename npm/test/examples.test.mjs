import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, readFile, writeFile, rm, symlink } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
const exec = promisify(execFile);
const cli = new URL("../bin/lawspec.mjs", import.meta.url).pathname;
test("examples exports all bundled stubs/tests, preserves adapters, and protects edited tests and paths", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "lawspec-examples-"));
  const run = (args = []) =>
    exec(process.execPath, [cli, "examples", "--json", ...args], { cwd: root });
  try {
    const result = JSON.parse((await run()).stdout);
    assert.equal(result.length, 8);
    for (const target of result) {
      assert.equal(target.files.filter(f => f.placement === "test" && !f.path.includes("support/")).length, 13);
      assert.ok(target.files.some(f => f.placement === "source" && f.ownership === "generated"));
      assert.equal(
        target.files.filter((f) => f.ownership === "user").length,
        13,
      );
      for (const f of target.files)
        assert.ok(
          (await readFile(path.join(target.directory, f.path), "utf8")).length,
        );
    }
    // Simulate upgrading a 0.4 Kotlin adapter while preserving its implementation.
    const kotlin = result.find((r) => r.target === "kotlin");
    const kotlinAdapter = "src/main/kotlin/example/BooleanFlags.kt";
    const legacy = "package example\nfun flipFlag(x: Boolean): Boolean = !x\n";
    await writeFile(path.join(kotlin.directory, kotlinAdapter), legacy);
    const manifestPath = path.join(kotlin.directory, ".lawspec/generated.json");
    const manifest = JSON.parse(await readFile(manifestPath, "utf8"));
    manifest.adapters[kotlinAdapter] = "previous-stub-shape";
    await writeFile(manifestPath, JSON.stringify(manifest));
    const migration = await exec(
      process.execPath,
      [cli, "examples", "--target", "kotlin"],
      { cwd: root },
    );
    assert.match(migration.stdout, /Review required adapter signatures/);
    assert.match(migration.stdout, /object BooleanFlags/);
    assert.equal(
      await readFile(path.join(kotlin.directory, kotlinAdapter), "utf8"),
      legacy,
    );
    const java = result.find((r) => r.target === "java");
    const adapter = path.join(
      java.directory,
      "src/main/java/example/Slug.java",
    );
    await writeFile(adapter, "// user implementation\n");
    const again = JSON.parse((await run()).stdout);
    assert.ok(again.every((t) => t.changes === 0));
    assert.equal(await readFile(adapter, "utf8"), "// user implementation\n");
    const test = path.join(
      java.directory,
      "src/test/java/example/SlugLawSpecTest.java",
    );
    await writeFile(test, "// user edit\n");
    await assert.rejects(run());
    assert.equal(await readFile(test, "utf8"), "// user edit\n");
    const single = JSON.parse(
      (await run(["--target", "python", "--output", "custom"])).stdout,
    );
    assert.equal(single.length, 1);
    await assert.rejects(run(["--output", "../escape"]));
    await symlink(root, path.join(root, "linked"));
    await assert.rejects(run(["--output", "linked"]));
    await assert.rejects(run(["--target", "unknown"]));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
