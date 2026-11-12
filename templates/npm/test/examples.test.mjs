import {generateInput} from './compiler-input.mjs';
import {createCompiler} from '../api.mjs';
import {programTargets as targets} from '../templates.mjs';
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, readdir, readFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
const exec = promisify(execFile);
const cli = new URL("../bin/lawspec.mjs", import.meta.url).pathname;
// The export of every target is compared with the API's own generation, and
// then repeated. The upgrade and protection cases are in
// examples-upgrade.test.mjs, on single targets, so the two files run at once.
test("examples exports all bundled stubs/tests as the API generates them, and a second export changes nothing", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "lawspec-examples-"));
  const run = (args = []) =>
    exec(process.execPath, [cli, "examples", "--json", ...args], {
      cwd: root, maxBuffer: 16 * 1024 * 1024,
    });
  try {
    const directory = new URL('../examples/specs/', import.meta.url);
    const sources = await Promise.all((await readdir(directory)).filter(n => n.endsWith('.lawspec')).sort().map(async name => ({
      path: name, content: await readFile(new URL(name, directory), 'utf8'),
    })));
    // The command line runs in its own process, so the API generates the
    // expected files while it works.
    const exported = run();
    const compiler = await createCompiler();
    const expected = new Map();
    for (const target of targets)
      expected.set(target, await generateInput(compiler, {sources, target}));
    const result = JSON.parse((await exported).stdout);
    assert.deepEqual(result.map(project => project.target), targets);
    for (const target of result) {
      const generated = expected.get(target.target);
      assert.equal(target.languageProfile, '1.0-rc.2');
      assert.deepEqual(generated.diagnostics, []);
      assert.deepEqual(target.files, generated.files.map(({path, ownership, placement}) => ({path, ownership, placement})));
      assert.ok(target.files.some(f => f.placement === "source" && f.ownership === "generated"));
      for (const f of target.files)
        assert.ok(
          (await readFile(path.join(target.directory, f.path), "utf8")).length,
        );
    }
    const again = JSON.parse((await run()).stdout);
    assert.ok(again.every((t) => t.changes === 0));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
