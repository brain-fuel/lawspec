// Generated from templates/tools/beam-coverage-check.mjs by lawspec-dev generate. Do not edit.
// Native coverage counters, export merging and source reports, without Hex.
// ref:DEC-never-pass-vacuously ref:DEC-tests-cite-requirements
import assert from "node:assert/strict";
import {execFile} from "node:child_process";
import {randomUUID} from "node:crypto";
import {cp, mkdir, mkdtemp, readFile, rm, writeFile} from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {fileURLToPath} from "node:url";
import {promisify} from "node:util";
import {collectBeamCoverage} from "../npm/beam-coverage.mjs";

const exec = promisify(execFile);
const repository = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const root = await mkdtemp(path.join(os.tmpdir(), "lawspec native coverage "));
try {
  const ebin = path.join(root, "ebin"), support = path.join(root, "support");
  const directory = path.join(root, ".lawspec/coverage"), source = path.join(root, "src/coverage_subject.erl");
  for (const folder of [ebin, support, path.dirname(source), path.join(directory, "runs")])
    await mkdir(folder, {recursive: true});
  await writeFile(source, [
    "-module(coverage_subject).", "-export([called/0, never/0, cleanup/0]).",
    "% <script>alert('source, not markup')</script>",
    "called() -> 7.", "never() -> 8.", "cleanup() -> ok.", "",
  ].join("\n"));
  await cp(path.join(repository, "runtime/lawspec_beam_runtime.erl"), path.join(root, "src/lawspec_beam_runtime.erl"));
  await exec("erlc", ["+debug_info", "-Werror", "-o", ebin, source,
    path.join(root, "src/lawspec_beam_runtime.erl")]);
  await exec("erlc", ["+debug_info", "-Werror", "-o", support,
    path.join(repository, "runtime/lawspec_beam_coverage.erl")]);
  const run = async (failure) => {
    const run = randomUUID();
    const descriptor = {run, file: path.join(directory, "runs", `${run}.coverdata`),
      metadata: path.join(directory, "runs", `${run}.json`)};
    await exec("erl", ["-noshell", "-pa", ebin, support, "-eval", `
      Coverage = lawspec_beam_coverage:start(),
      try
        7 = coverage_subject:called(),
        case os:getenv("EXPECT_FAILURE") of "true" -> error(expected_failure); _ -> ok end
      catch error:expected_failure -> ok
      after
        ok = coverage_subject:cleanup(), lawspec_beam_coverage:finish(Coverage)
      end,
      halt().`], {cwd: root, env: {...process.env,
      LAWSPEC_BEAM_COVERAGE: JSON.stringify(descriptor), EXPECT_FAILURE: String(failure)}});
    return descriptor;
  };
  const runs = [await run(false), await run(true)];
  const report = await collectBeamCoverage({root, directory, runs});
  const subject = report.modules.find(({name}) => name === "coverage_subject");
  assert.deepEqual(subject.lines, [{line: 4, hits: 2}, {line: 5, hits: 0}, {line: 6, hits: 2}]);
  assert.deepEqual(subject.summary, {covered: 2, total: 3});
  assert.equal(subject.source, "src/coverage_subject.erl");
  const html = await readFile(path.join(directory, "modules", subject.report), "utf8");
  assert.match(html, /&lt;script&gt;/);
  assert.doesNotMatch(html, /<script>/);
  assert.match(html, /class="miss" id="L5"/);
  assert.match(await readFile(path.join(directory, "index.html"), "utf8"), /2 native run\(s\)/);

  // Rebar exports have no companion metadata; OTP produces their source HTML.
  const native = await collectBeamCoverage({root, directory: path.join(root, "native report"),
    runs: runs.map(({metadata, ...run}) => run)});
  assert.deepEqual(native.modules.find(({name}) => name === "coverage_subject").lines, subject.lines);

  // A truncated export must not produce an index or a successful summary.
  const broken = {run: randomUUID()};
  broken.file = path.join(directory, "runs", `${broken.run}.coverdata`);
  await writeFile(broken.file, "not a cover export");
  await assert.rejects(collectBeamCoverage({root, directory: path.join(root, "broken"), runs: [broken]}));
  console.log("BEAM coverage: real counters, merged exports, cleanup after failure, HTML escaping and invalid exports passed.");
} finally {
  await rm(root, {recursive: true, force: true});
}
