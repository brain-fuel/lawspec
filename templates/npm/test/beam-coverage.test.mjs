import {test} from "node:test";
import assert from "node:assert/strict";
import {access, mkdtemp, rm, writeFile} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {beamCoverageRequirement, collectBeamCoverage} from "../beam-coverage.mjs";

test("native coverage requires a supported exporter and accurate source locations", () => {
  assert.equal(beamCoverageRequirement({language: "erlang"}, {}), null);
  assert.equal(beamCoverageRequirement({language: "elixir"}, {coverage: {tool: "Mix.Tasks.Test.Coverage"}}), null);
  assert.match(beamCoverageRequirement({language: "elixir"}, {coverage: {tool: "Custom"}}).tool, /Mix.Tasks.Test.Coverage/);
  assert.equal(beamCoverageRequirement({language: "gleam"}, {versions: {gleam: "1.19.0"}}), null);
  assert.match(beamCoverageRequirement({language: "gleam"}, {versions: {gleam: "1.18.1"}}).tool, /Gleam 1.19/);
  assert.match(beamCoverageRequirement({language: "gleam"}, {}).tool, /Gleam 1.19/);
});

// Native counter and source mapping checks live with the BEAM integration
// gates. These input checks require no installed BEAM toolchain.
async function fixture(t) {
  const root = await mkdtemp(path.join(os.tmpdir(), "lawspec-coverage-"));
  t.after(() => rm(root, {recursive: true, force: true}));
  const directory = path.join(root, "report");
  const run = {run: "current", file: path.join(root, "current.coverdata")};
  return {root, directory, run, collect: (runs) => collectBeamCoverage({root, directory, runs})};
}

test("no native runs produce no coverage claim", async t => {
  const f = await fixture(t);
  assert.equal(await f.collect([]), null);
  await assert.rejects(access(f.directory));
});

test("missing and empty native exports cannot be replaced by a previous run", async t => {
  const f = await fixture(t);
  await writeFile(path.join(f.root, "previous.coverdata"), "old export");
  await assert.rejects(f.collect([f.run]), /did not export coverage for current/);
  await writeFile(f.run.file, "");
  await assert.rejects(f.collect([f.run]), /did not export coverage for current/);
  await assert.rejects(access(path.join(f.directory, "index.html")));
});

test("coverage invocation identity and uniqueness are required", async t => {
  const f = await fixture(t);
  await writeFile(f.run.file, "export placeholder");
  await assert.rejects(f.collect([{...f.run, run: "other"}]), /Invalid or duplicate/);
  await assert.rejects(f.collect([f.run, f.run]), /Invalid or duplicate/);
  await assert.rejects(access(f.directory));
});

test("Gleam source metadata must be sealed for the same export", async t => {
  const f = await fixture(t);
  const run = {...f.run, metadata: path.join(f.root, "current.json")};
  await writeFile(run.file, "export placeholder");
  for (const value of [{run: "previous", file: run.file, modules: [{name: "subject", beam: "subject.beam"}]},
    {run: run.run, file: "other.coverdata", modules: [{name: "subject", beam: "subject.beam"}]},
    {run: run.run, file: run.file, modules: []}]) {
    await writeFile(run.metadata, JSON.stringify(value));
    await assert.rejects(f.collect([run]), /does not match invocation/);
  }
  await assert.rejects(access(f.directory));
});
