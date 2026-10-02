import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, mkdir, readdir, readFile, writeFile, rm } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
const exec = promisify(execFile);
const cli = new URL("../bin/lawspec.mjs", import.meta.url).pathname;
const spec = [
  "unit cache.example",
  "double :: Int32 -> Int32",
  "definition twice (x :: BigInt) :: BigInt is x + x end",
  "law `twice doubles` is definition is `for all` (x :: BigInt) . twice x = x * 2 end end",
  "law `double is deterministic` is definition is `for all` (x :: Int32) . double x = double x end end",
].join("\n") + "\n";
async function project(t, config = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), "lawspec-cache-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(path.join(root, "laws"));
  await writeFile(path.join(root, "laws/example.lawspec"), spec);
  await writeFile(path.join(root, "lawspec.json"), JSON.stringify({
    version: 1, sources: ["laws"], targets: [{ language: "python", root: "." }], ...config,
  }));
  return root;
}
const check = (root, ...flags) => exec(process.execPath, [cli, "check", "--json", ...flags], { cwd: root })
  .then((result) => result.stdout);
async function entries(folder) {
  const found = [];
  for (const entry of await readdir(folder, { withFileTypes: true }))
    if (entry.isDirectory()) found.push(...await entries(path.join(folder, entry.name)));
    else found.push(path.join(folder, entry.name));
  return found;
}
test("check reuses work kept in .lawspec/cache, and recovers from a damaged entry", async (t) => {
  const root = await project(t);
  const first = await check(root);
  const cache = path.join(root, ".lawspec/cache");
  assert.equal(await readFile(path.join(cache, ".gitignore"), "utf8"), "*\n");
  const builds = (await readdir(cache)).filter((name) => name !== ".gitignore");
  assert.equal(builds.length, 1);
  const stored = await entries(path.join(cache, builds[0]));
  assert.ok(stored.length > 0);
  assert.equal(await check(root), first);
  await writeFile(stored[0], "damaged");
  assert.equal(await check(root), first);
  // Another compiler build's folder is removed.
  await mkdir(path.join(cache, "0000000000000000"));
  await check(root);
  assert.deepEqual((await readdir(cache)).sort(), [".gitignore", builds[0]].sort());
});
test("--no-cache and cache: false keep no cache", async (t) => {
  const flagged = await project(t);
  await check(flagged, "--no-cache");
  await assert.rejects(readdir(path.join(flagged, ".lawspec/cache")));
  const configured = await project(t, { cache: false });
  await check(configured);
  await assert.rejects(readdir(path.join(configured, ".lawspec/cache")));
  const invalid = await project(t, { cache: "yes" });
  await assert.rejects(check(invalid), /cache must be true or false/);
});
