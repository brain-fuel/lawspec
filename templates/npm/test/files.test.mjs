import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, readFile, writeFile, rm, symlink } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
import { planWrites, applyWrites, readOptional } from "../files.mjs";
const artifacts = [
  { path: "src/adapter.py", content: "user stub\n", ownership: "user" },
  { path: "tests/test_law.py", content: "generated\n", ownership: "generated" },
];
async function project(t) {
  const p = await mkdtemp(path.join(os.tmpdir(), "lawspec-test-"));
  t.after(() => rm(p, { recursive: true, force: true }));
  return p;
}
test("regeneration preserves modified user adapters and is idempotent", async (t) => {
  const p = await project(t);
  await applyWrites([await planWrites(p, artifacts)]);
  await writeFile(path.join(p, "src/adapter.py"), "real implementation\n");
  const plan = await planWrites(p, artifacts);
  assert.equal(plan.changes.length, 0);
  assert.equal(
    await readFile(path.join(p, "src/adapter.py"), "utf8"),
    "real implementation\n",
  );
});
test("edited generated files and unowned identical files are protected", async (t) => {
  const p = await project(t);
  await applyWrites([await planWrites(p, artifacts)]);
  await writeFile(path.join(p, "tests/test_law.py"), "manual edit\n");
  await assert.rejects(planWrites(p, artifacts), /edited/);
  await rm(path.join(p, ".lawspec"), { recursive: true });
  await writeFile(path.join(p, "tests/test_law.py"), "generated\n");
  await assert.rejects(planWrites(p, artifacts), /unowned/);
});
test("stale owned tests are removed but user adapters remain", async (t) => {
  const p = await project(t);
  await applyWrites([await planWrites(p, artifacts)]);
  await applyWrites([await planWrites(p, [])]);
  assert.equal(await readOptional(path.join(p, "tests/test_law.py")), null);
  assert.equal(
    await readFile(path.join(p, "src/adapter.py"), "utf8"),
    "user stub\n",
  );
});
test("concurrent edits abort all planned writes", async (t) => {
  const p = await project(t);
  await applyWrites([await planWrites(p, artifacts)]);
  const plan = await planWrites(p, [
    artifacts[0],
    { ...artifacts[1], content: "new generated\n" },
  ]);
  await writeFile(path.join(p, "tests/test_law.py"), "concurrent edit\n");
  await assert.rejects(applyWrites([plan]), /changed during generation/);
  assert.equal(
    await readFile(path.join(p, "tests/test_law.py"), "utf8"),
    "concurrent edit\n",
  );
});
test("path traversal and symlink output paths are refused", async (t) => {
  const p = await project(t);
  const outside = await project(t);
  await assert.rejects(
    planWrites(p, [{ ...artifacts[0], path: "../outside.py" }]),
    /Unsafe/,
  );
  await symlink(outside, path.join(p, "src"));
  await assert.rejects(planWrites(p, artifacts), /symbolic-link/);
});
