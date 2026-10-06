#!/usr/bin/env node
// Generated from templates/npm/bin/lawspec.mjs by lawspec-dev generate. Do not edit.
import { readFile, mkdir, readdir, rm, stat, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import path from "node:path";
import { createCompiler } from "../api.mjs";
import { targets, templates, commands, setup } from "../templates.mjs";
import { generateExamples } from "../examples-command.mjs";
import { showScalar } from "../scalars.mjs";
import { doctor } from "../doctor.mjs";
import { spawn, spawnSync } from "node:child_process";
import { benchmarkInvocations, environmentDigest, executedTests, invocations, lawKeys, projectDigest, recordedDigest, selectByTags, mergeJunit,
  harnessStatistics, coverageTools, junitFromTests } from "../test-command.mjs";
import {
  readOptional,
  planWrites,
  applyWrites,
  atomicWrite,
  safePath,
} from "../files.mjs";
const VERSION = "0.20.0";
const args = process.argv.slice(2);
const verb = args.shift();
const options = {};
const positional = [];
for (let i = 0; i < args.length; i++) {
  const arg = args[i];
  if (["--target", "--project", "--config", "--output", "--machine-bits", "--example", "--seed", "--report"].includes(arg)) {
    if (!args[i + 1] || args[i + 1].startsWith("--"))
      throw new Error(`Missing value for ${arg}`);
    options[arg.slice(2)] = args[++i];
  } else if (["--tag", "--exclude-tag"].includes(arg)) {
    // Repeatable, and each may list several: --tag a,b --tag c.
    if (!args[i + 1] || args[i + 1].startsWith("--"))
      throw new Error(`Missing value for ${arg}`);
    options[arg.slice(2)] = [...(options[arg.slice(2)] ?? []), ...args[++i].split(",").filter(Boolean)];
  } else if (["--dry-run", "--check", "--json", "--minify", "--no-cache", "--fresh", "--coverage", "--update-recorded", "--benchmarks"].includes(arg))
    options[arg.slice(2)] = true;
  else if (arg.startsWith("--")) throw new Error(`Unknown option: ${arg}`);
  else positional.push(arg);
}
const configFile = path.resolve(options.config || "lawspec.json");
const configRoot = path.dirname(configFile);
const output = (value) =>
  console.log(
    typeof value === "string" ? value : JSON.stringify(value, null, 2),
  );
const shellQuote = (value) =>
  "'" + String(value).replaceAll("'", "'\\''") + "'";
function testCommand(target, root) {
  const testDir = target.testDir || "test";
  let command = commands[target.language];
  if (target.language === "python")
    command = `${shellQuote(target.python || "python3")} -m pytest`;
  if (target.language === "java")
    command = `${shellQuote(target.maven || "mvn")} test`;
  if (target.language === "kotlin")
    command = `${shellQuote(target.gradle || "gradle")} test`;
  if (target.language === "javascript")
    command = `node --test ${shellQuote(testDir)}/*.test.mjs`;
  if (target.language === "typescript")
    command = `npm exec -- tsc -p tsconfig.json && node --test ${shellQuote("dist/" + testDir)}/*.test.js`;
  return `(cd ${shellQuote(root)} && ${command})`;
}
function diagnostics(result) {
  if (result.diagnostics?.length)
    throw Object.assign(
      new Error(
        result.diagnostics
          .map(
            (d) =>
              `${d.at ? `${d.at.file}:${d.at.line}:${d.at.column}: ` : ""}${d.code}: ${d.message}`,
          )
          .join("\n"),
      ),
      { diagnostics: result.diagnostics },
    );
  return result;
}
async function sources(config) {
  return lawspecFiles(configRoot, config.sources);
}
async function lawspecFiles(root, entries) {
  const files = [];
  async function visit(file) {
    const info = await stat(file);
    if (info.isDirectory())
      for (const entry of (await readdir(file)).sort())
        await visit(path.join(file, entry));
    else if (file.endsWith(".lawspec")) files.push(file);
  }
  for (const source of entries) await visit(path.resolve(root, source));
  if (!files.length) throw new Error("No .lawspec source files found");
  return Promise.all(
    [...new Set(files)].sort().map(async (file) => ({
      path: path.relative(configRoot, file).split(path.sep).join("/"),
      content: await readFile(file, "utf8"),
    })),
  );
}
// A package directory holds lawspec-package.json: its name, version, source
// directories and dependency ranges. The compiler checks names, versions,
// namespaces and which units may import which.
async function loadPackage(directory) {
  const file = path.join(directory, "lawspec-package.json");
  const manifest = JSON.parse(await readFile(file, "utf8"));
  if (
    typeof manifest.name !== "string" ||
    typeof manifest.version !== "string" ||
    !Array.isArray(manifest.sources)
  )
    throw new Error(`${file}: expected name, version and a sources array`);
  return {
    manifest,
    package: {
      name: manifest.name,
      version: manifest.version,
      dependencies: manifest.dependencies ?? {},
      sources: await lawspecFiles(directory, manifest.sources),
    },
  };
}
async function packageInput(owner, root) {
  if (owner.packages !== undefined && !Array.isArray(owner.packages))
    throw new Error("packages must be an array of package directories");
  const packages = await Promise.all(
    (owner.packages ?? []).map(async (p) => (await loadPackage(path.resolve(root, p))).package),
  );
  return {
    ...(packages.length ? { packages } : {}),
    ...(owner.dependencies !== undefined ? { dependencies: owner.dependencies } : {}),
  };
}
async function packageCommand() {
  const directory = path.resolve(options.project || ".");
  const { manifest, package: own } = await loadPackage(directory);
  const compiler = await createCompiler();
  const result = diagnostics(
    await compiler.check({
      sources: own.sources,
      package: { name: own.name, version: own.version },
      ...(await packageInput(manifest, directory)),
      machineBits: options.machineBits ?? 64,
    }),
  );
  // A package owns the units in its namespace; its dependencies' units are not its own.
  const units = result.units
    .map((u) => u.id)
    .filter((u) => u === own.name || u.startsWith(own.name + "."));
  const laws = result.laws.filter((l) => units.includes(l.owner));
  const summary = {
    name: own.name,
    version: own.version,
    dependencies: own.dependencies,
    units,
    laws: laws.map((l) => `${l.owner}::${l.name}`),
    dataTypes: result.dataTypes
      .filter((d) => units.some((u) => d.id.startsWith(u + "::")))
      .map((d) => d.id),
  };
  output(
    options.json
      ? summary
      : `${summary.name} ${summary.version}: ${units.length} unit(s), ${summary.laws.length} law(s), ${summary.dataTypes.length} data type(s).
` +
          `Units: ${units.join(", ")}
` +
          `Dependencies: ${Object.entries(summary.dependencies).map(([n, r]) => `${n} ${r}`).join(", ") || "none"}`,
  );
}
async function init() {
  const language = options.target;
  if (!targets.includes(language))
    throw new Error(`Choose --target ${targets.join("|")}`);
  const root = path.resolve(configRoot, options.project || ".");
  const current = await readOptional(configFile);
  const config =
    current === null
      ? { version: 1, sources: ["laws"], targets: [] }
      : JSON.parse(current);
  if (
    config.targets.some(
      (t) =>
        t.language === language && path.resolve(configRoot, t.root) === root,
    )
  )
    throw new Error("Target is already configured");
  await mkdir(root, { recursive: true });
  const buildFiles = [
    "Cargo.toml",
    "pom.xml",
    "pyproject.toml",
    "package.json",
    "go.mod",
    "stack.yaml",
    "package.yaml",
    "build.gradle",
    "build.gradle.kts",
    "settings.gradle.kts",
  ];
  const hasBuild = (await readdir(root)).some(
    (f) => buildFiles.includes(f) || f.endsWith(".cabal"),
  );
  const additions = hasBuild ? {} : templates(language, {minify: options.minify === true});
  for (const name of Object.keys(additions)) {
    const file = await safePath(root, name);
    if ((await readOptional(file)) !== null)
      throw new Error(`Will not overwrite ${file}`);
  }
  const starter = await safePath(configRoot, "laws/atoi_codec.lawspec");
  await safePath(configRoot, path.basename(configFile));
  if (current === null && (await readOptional(starter)) !== null)
    throw new Error(
      "Starter specification already exists; create lawspec.json manually to use it",
    );
  if (!hasBuild && language !== "go")
    await mkdir(path.join(root, "src"), { recursive: true });
  for (const [name, content] of Object.entries(additions))
    await atomicWrite(path.join(root, name), content, true);
  if (current === null)
    await atomicWrite(
      starter,
      await readFile(new URL("../starter.lawspec", import.meta.url), "utf8"),
      true,
    );
  if (options.machineBits !== undefined) config.machineBits = options.machineBits;
  config.targets.push({
    language,
    root: path.relative(configRoot, root) || ".",
  });
  await atomicWrite(
    configFile,
    JSON.stringify(config, null, options.minify ? undefined : 2) + "\n",
    current === null,
  );
  output(
    `Configured ${language}. ${hasBuild ? "Existing build files preserved." : "Created missing project build files."}\n${setup[language]}\nNext: lawspec doctor, then lawspec generate.`,
  );
}
function showAssertion(assertion) {
  if (assertion.kind === "equal") return `${assertion.left.text} = ${assertion.right.text}`;
  if (assertion.kind === "implies") return `${assertion.guard.text} implies ${showAssertion(assertion.body)}`;
  return assertion.items.map(showAssertion).join(" and ");
}
// An ability key, as the spec names it: example.shop::ability::Store(Int32)
// is Store Int32, lawspec::ability::Fail(example.shop::type::E) is Fail E.
function abilityName(key) {
  const short = (text) => text.replace(/[A-Za-z0-9_.]+::(ability|type)::/g, "");
  const match = /^(.*?)(\((.*)\))?$/.exec(short(key));
  return match[3] ? `${match[1]} ${match[3].replace(/[()]/g, " ").replace(/;/g, " ").trim()}` : match[1];
}
// The handlers a law runs under, and the ability row of each function its
// expansion calls.
function explainAbilities(law, expansion, units) {
  const unit = (units || []).find((u) => u.id === law.owner);
  const called = (unit ? unit.declarations : []).filter(
    (d) => d.uses && new RegExp(`\\b${d.name}\\b`).test(expansion),
  );
  const handlers = (law.handlers || []).map((h) => `\n  ${abilityName(h.ability)}: ${h.handler}`).join("");
  const rows = called.map((d) => `\n  ${d.name} uses ${d.uses.map(abilityName).join(", ")}`).join("");
  return (handlers ? `\nhandlers${handlers}` : "") + (rows ? `\nrows${rows}` : "");
}
function explainExamples(law) {
  return law.examples.map(ex =>
    `\nexample ${JSON.stringify(ex.name)}\n` +
    ex.bindings.map(b => `  ${b.name} = ${showScalar(b.value)}`).join("\n") + "\n" +
    ex.expectations.map(e => `  expect ${showAssertion(e)}`).join("\n")
  ).join("\n");
}
// What lawspec test last recorded for each law, across targets.
async function lastRuns() {
  const folder = path.join(configRoot, ".lawspec", "results");
  const runs = new Map();
  for (const name of (await readOptionalDirectory(folder)) ?? []) {
    if (!name.endsWith(".json")) continue;
    const recorded = JSON.parse((await readOptional(path.join(folder, name))) ?? "{}");
    for (const [law, run] of Object.entries(recorded.laws ?? {})) {
      const known = runs.get(law) ?? {};
      runs.set(law, { flaky: known.flaky || run.flaky, adequacy: run.adequacy ?? known.adequacy });
    }
  }
  return runs;
}
// One law's harness, as lawspec evidence shows it.
function harnessText(item) {
  const h = item.harness ?? {};
  const parts = [];
  if (h.unit) parts.push(`harness ${h.unit}`);
  if (h.tags?.length) parts.push(`tags ${h.tags.join(", ")}`);
  if (h.strategies?.length) parts.push(h.strategies.map((s) => `${s.input} drawn by ${s.strategy}`).join(", "));
  for (const c of h.cover ?? []) parts.push(`cover ${c.percent}% "${c.label}" when ${c.when.text}`);
  for (const c of h.classify ?? []) parts.push(`classify ${c.when.text} as "${c.label}"`);
  for (const l of h.labels ?? []) parts.push(`label ${l.text}`);
  if (h.target) parts.push(`target maximize ${h.target.text}`);
  if (h.timeoutMilliseconds) parts.push(`timeout ${h.timeoutMilliseconds} ms`);
  if (h.repeat > 1) parts.push(`repeat ${h.repeat}`);
  if (h.retries) parts.push(`retry flaky ${h.retries}`);
  if (h.skip) parts.push(`skip "${h.skip}"`);
  if (h.knownFailing) parts.push(`known failing "${h.knownFailing}"`);
  if (h.orderRandom) parts.push("order random");
  // Python runs a parallel unit's tests at the same time only with
  // pytest-xdist; without it, parallel changes nothing there.
  if (h.parallel) parts.push("parallel (on Python only with pytest-xdist; otherwise one after another)");
  const lines = [`  ${item.declaration.replace("::law::", "::")}: ${parts.join("; ") || "no harness settings"}`];
  for (const run of item.adequacy ?? []) {
    lines.push(`    last run: ${run.cases} generated case(s)` +
      (run.cover ?? []).map((c) => `; cover "${c.label}" ${c.observed}% (needs ${c.required}%)${c.met ? "" : " NOT MET"}`).join(""));
    const counts = { ...(run.classes ?? {}), ...Object.fromEntries(Object.entries(run.labels ?? {}).map(([k, v]) => [`label ${k}`, v])) };
    if (Object.keys(counts).length)
      lines.push(`    ${Object.entries(counts).map(([k, v]) => `${k}: ${run.cases ? (100 * v / run.cases).toFixed(1) : 0}%`).join(", ")}`);
  }
  return lines.join("\n");
}
// The compiler keeps work between runs in .lawspec/cache, in one folder per
// compiler build, so a different build never reads another's entries. The
// WebAssembly compiler sees only the working directory. A command that fails
// removes the .lawspec folder if it created it, leaving the project as it was.
let createdState = null;
async function cacheDirectory(config) {
  if (options["no-cache"] || config.cache === false) return undefined;
  const folder = path.join(configRoot, ".lawspec", "cache");
  const relative = path.relative(process.cwd(), folder);
  if (relative.startsWith("..") || path.isAbsolute(relative)) return undefined;
  const build = (await buildDigest()).slice(0, 16);
  const state = path.join(configRoot, ".lawspec");
  if ((await readOptionalDirectory(state)) === null) createdState = state;
  await mkdir(path.join(folder, build), { recursive: true });
  await writeFile(path.join(folder, ".gitignore"), "*\n");
  for (const entry of await readdir(folder))
    if (entry !== build && entry !== ".gitignore")
      await rm(path.join(folder, entry), { recursive: true, force: true });
  return path.join(relative, build).split(path.sep).join("/");
}
// The compiler build, by the digest of its WebAssembly module.
let buildDigestValue = null;
async function buildDigest() {
  buildDigestValue ??= createHash("sha256")
    .update(await readFile(new URL("../core.wasm", import.meta.url)))
    .digest("hex");
  return buildDigestValue;
}
// lawspec test: run the tests of the laws whose results may have changed,
// and record each passing law's key and seed (see test-command.mjs). The
// harness plane chooses which: --tag and --exclude-tag select laws by their
// harness tags, and a skipped law runs nothing. A law whose last run failed
// runs first, and its failing inputs are replayed first (.lawspec/failures).
async function runTests(compiler, input, selected, roots, config) {
  // Recorded values live beside lawspec.json, under recorded/<unit>/<name>.
  const recordedFolder = path.join(configRoot, "recorded");
  const seed = options.seed ?? String(1 + Math.floor(Math.random() * 2147483646));
  const offline = process.env.LAWSPEC_OFFLINE === "1";
  const build = await buildDigest();
  const summaries = [];
  const junit = [];
  const report = options.report === undefined ? null : parseReport(options.report);
  for (const [i, target] of selected.entries()) {
    const root = roots[i];
    const planned = diagnostics(await compiler.planGeneration({
      ...input, target: target.language, sourceDir: target.sourceDir, testDir: target.testDir,
      nativeBindings: target.nativeBindings, minify: options.minify === true,
    }));
    const pending = await planWrites(root, planned.files);
    if (pending.changes.length)
      throw new Error(`${target.language}: generated files are out of date; run lawspec generate${options.minify ? " --minify" : ""}`);
    const report_ = await doctor(target, root, planned.files);
    if (!report_.ok) throw new Error(`${target.language}: ${report_.message}\n${report_.instructions}`);
    const generated = new Set(planned.files.filter((f) => f.ownership === "generated").map((f) => f.path));
    const keys = lawKeys({
      build, target, machineBits: input.machineBits, minify: options.minify === true,
      tests: planned.tests, files: planned.files,
      // Recorded values are spec data: a changed recording runs its laws again.
      environment: await environmentDigest(root, report_) + (await recordedDigest(recordedFolder)),
      project: await projectDigest(root, generated),
    });
    const resultsFile = path.join(configRoot, ".lawspec", "results",
      `${target.language}-${createHash("sha256").update(root).digest("hex").slice(0, 12)}.json`);
    const previous = JSON.parse((await readOptional(resultsFile)) ?? '{"version":1,"laws":{}}');
    // Recording again runs every law, so each records what it sees now.
    const chosen = selectByTags(planned.tests, options.tag ?? [], options["exclude-tag"] ?? []);
    const stale = chosen.filter((entry) => options.fresh || options.coverage || options["update-recorded"] || previous.laws[entry.law]?.key !== keys.get(entry.law));
    // The failure database: each law whose last run failed, with the seed
    // that exposed it. Those laws run first, with that seed, so the failing
    // inputs are generated again; the runtimes keep their own counterexample
    // databases beside it (Hypothesis, proptest).
    const failures = path.join(configRoot, ".lawspec", "failures", target.language);
    const databaseFile = path.join(failures, "laws.json");
    const database = JSON.parse((await readOptional(databaseFile)) ?? "{}");
    const replayed = options.seed === undefined ? stale.filter((entry) => database[entry.law]) : [];
    const batches = [
      ...[...new Set(replayed.map((entry) => database[entry.law].seed))].map((s) =>
        ({ seed: String(s), entries: replayed.filter((entry) => database[entry.law].seed === s) })),
      { seed, entries: stale.filter((entry) => !replayed.includes(entry)) },
    ].filter((batch) => batch.entries.length);
    const passed = [];
    const unrun = [];
    let failed = false;
    const scratch = path.join(configRoot, ".lawspec", "reports", target.language);
    const stats = path.join(scratch, "statistics");
    const coverage = options.coverage ? path.join(configRoot, ".lawspec", "coverage", target.language) : null;
    await rm(scratch, { recursive: true, force: true });
    await mkdir(stats, { recursive: true });
    await mkdir(failures, { recursive: true });
    await writeFile(path.join(path.dirname(scratch), ".gitignore"), "*\n");
    if (coverage) {
      await mkdir(coverage, { recursive: true });
      const missing = await coverageMissing(target, root);
      if (missing) console.error(`${target.language}: --coverage needs ${missing.tool}, which is not available; ${missing.install}. Running without coverage.`);
    }
    const useCoverage = coverage && !(await coverageMissing(target, root));
    // parallel on Python needs pytest-xdist; without it the tests run one
    // after another, and lawspec test says so.
    let xdist = false;
    if (target.language === "python" && stale.some((entry) => entry.parallel)) {
      xdist = spawnSync(target.python || "python3", ["-c", "import xdist"], { cwd: root, stdio: "ignore" }).status === 0;
      if (!xdist) console.error("python: `parallel` runs tests at the same time only with pytest-xdist (pip install pytest-xdist); without it they run one after another.");
    }
    // A skipped law runs nothing, and a known-failing law's one test is
    // expected to fail, so neither is required to show as run.
    const expected = (entry) => !entry.skip && !entry.knownFailing;
    const seedOf = new Map();
    batches: for (const batch of batches) {
      for (const run of invocations(target, batch.entries, { offline, scratch, coverage: useCoverage ? coverage : null, xdist })) {
        const since = Date.now() - 1000;
        const { ok, output } = await spawned(run.command, run.args, root,
          { ...process.env, ...run.env, LAWSPEC_SEED: batch.seed, HSPEC_SEED: batch.seed,
            LAWSPEC_STATS: stats, LAWSPEC_FAILURES: failures, LAWSPEC_RECORDED: recordedFolder,
            ...(options["update-recorded"] ? { LAWSPEC_UPDATE_RECORDED: "1" } : {}) }, run.report?.kind === "go-json");
        const executed = await executedTests(run.report, output, root, since);
        for (const law of run.laws) seedOf.set(law.law, batch.seed);
        if (report) junit.push({ target: target.language, xml: await junitOf(run, executed, root, since) });
        if (!ok) { failed = true; break batches; }
        // A runner whose filter matched nothing reports success, so a law
        // counts as passed only if the runner's report shows its tests ran.
        const ran = new Set(executed.flatMap(run.ran ?? (() => [])));
        passed.push(...run.laws.filter((law) => ran.has(law) || !expected(law)));
        unrun.push(...run.laws.filter((law) => !ran.has(law) && expected(law)));
      }
    }
    if (unrun.length) failed = true;
    // --benchmarks: the harness's benchmarks run after the laws, every time;
    // they are measured, never asserted, and never cached.
    const benchmarking = options.benchmarks ? (planned.benchmarks ?? []) : [];
    if (!failed) for (const run of benchmarkInvocations(target, benchmarking, { offline })) {
      const { ok } = await spawned(run.command, run.args, root,
        { ...process.env, ...run.env, LAWSPEC_SEED: seed, HSPEC_SEED: seed, LAWSPEC_STATS: stats, LAWSPEC_RECORDED: recordedFolder }, false);
      if (!ok) { failed = true; break; }
    }
    const statistics = await harnessStatistics(stats);
    const laws = Object.fromEntries(planned.tests.filter((entry) => previous.laws[entry.law]).map((entry) => [entry.law, previous.laws[entry.law]]));
    for (const entry of passed) {
      const label = entry.label;
      const observed = statistics.filter((s) => s.law === label);
      laws[entry.law] = { key: keys.get(entry.law), seed: Number(seedOf.get(entry.law) ?? seed), passed: new Date().toISOString(),
        ...(observed.some((s) => s.outcome === "flaky") ? { flaky: true } : {}),
        ...(observed.some((s) => s.cover || s.labels || s.classes) ? { adequacy: observed.filter((s) => s.cover || s.labels || s.classes)
          .map(({ test, cases, cover, classes, labels }) => ({ test, cases, cover, classes, labels })) } : {}) };
    }
    // A law that failed is recorded with its seed; one that passed leaves.
    for (const entry of stale) {
      if (passed.includes(entry)) delete database[entry.law];
      else if (seedOf.has(entry.law)) database[entry.law] = { seed: Number(seedOf.get(entry.law)), failed: new Date().toISOString() };
    }
    await writeFile(path.join(path.dirname(failures), ".gitignore"), "*\n");
    await writeFile(databaseFile, JSON.stringify(database, null, 2) + "\n");
    await mkdir(path.dirname(resultsFile), { recursive: true });
    await writeFile(path.join(path.dirname(resultsFile), ".gitignore"), "*\n");
    await writeFile(resultsFile, JSON.stringify({ version: 1, laws }, null, 2) + "\n");
    const flaky = statistics.filter((s) => s.outcome === "flaky").map((s) => s.law);
    const unmet = statistics.flatMap((s) => (s.cover ?? []).filter((c) => !c.met).map((c) => `${s.law}: cover ${c.required}% "${c.label}" (${c.observed}%)`));
    const benchmarks = statistics.filter((s) => s.benchmark);
    // How each parallel unit's tests actually ran at the same time.
    const parallelism = statistics.filter((s) => s.parallel).map(({ parallel, mode, workers }) => ({ unit: parallel, mode, workers }));
    summaries.push({ target: target.language, seed: Number(seed), ran: stale.map((e) => e.law),
      unchanged: chosen.length - stale.length, ok: !failed,
      ...(chosen.length !== planned.tests.length ? { deselected: planned.tests.length - chosen.length } : {}),
      ...(unrun.length ? { unrun: unrun.map((e) => e.law) } : {}),
      ...(flaky.length ? { flaky: [...new Set(flaky)] } : {}),
      ...(unmet.length ? { unmetCover: unmet } : {}),
      ...(benchmarks.length ? { benchmarks } : {}),
      ...(parallelism.length ? { parallelism } : {}),
      ...(useCoverage ? { coverage: path.relative(process.cwd(), coverage) || "." } : {}) });
  }
  if (report) {
    await mkdir(path.dirname(path.resolve(report.path)), { recursive: true });
    await writeFile(path.resolve(report.path), mergeJunit(junit));
  }
  output(options.json ? summaries : summaries.map((s) =>
    `${s.target}: ${s.ran.length ? `ran ${s.ran.length} law(s) with seed ${s.seed}` : "nothing to run"}` +
    `, ${s.unchanged} unchanged since their last passing run.${s.ok ? "" : " FAILED"}` +
    (s.deselected ? `\n${s.deselected} law(s) not selected by --tag or --exclude-tag.` : "") +
    (s.unrun ? `\nNo tests ran for ${s.unrun.join(", ")}; the runner matched none of their tests.` : "") +
    (s.flaky ? `\nFlaky (failed, then passed on a retry): ${s.flaky.join(", ")}` : "") +
    (s.unmetCover ? `\nCover not met: ${s.unmetCover.join("; ")}` : "") +
    (s.parallelism ? "\n" + s.parallelism.map((p) => `parallel ${p.unit}: ${p.mode}, ${p.workers} worker(s)`).join("\n") : "") +
    (s.benchmarks ? "\n" + s.benchmarks.map((b) => `benchmark ${b.benchmark}: mean ${(b.mean_ns / 1000).toFixed(2)} us over ${b.iterations} iteration(s)`).join("\n") : "") +
    (s.coverage ? `\nCoverage written to ${s.coverage}.` : "")).join("\n"));
  if (summaries.some((s) => !s.ok)) process.exitCode = 1;
}
// --report junit=path: one JUnit report merged across targets.
function parseReport(value) {
  const match = value.match(/^junit=(.+)$/);
  if (!match) throw new Error("--report takes junit=<path>");
  return { kind: "junit", path: match[1] };
}
// A run's JUnit XML: the runner's own where it writes one, otherwise made
// from what it printed.
async function junitOf(run, executed, root, since) {
  if (run.report?.kind === "junit") {
    const files = run.report.files ?? (await readdir(path.join(root, run.report.directory)).catch(() => []))
      .filter((n) => n.endsWith(".xml")).map((n) => path.join(root, run.report.directory, n));
    const xml = [];
    for (const file of files) {
      const info = await stat(path.resolve(root, file)).catch(() => null);
      if (info && info.mtimeMs >= since) xml.push(await readFile(path.resolve(root, file), "utf8"));
    }
    return xml.join("\n");
  }
  return junitFromTests(executed);
}
// The tool --coverage needs, if it is missing.
async function coverageMissing(target, root) {
  const tool = coverageTools[target.language];
  if (!tool) return { tool: "a coverage tool", install: "no coverage tool is known for this target" };
  const probe = (command, args) => new Promise((resolve) => {
    const child = spawn(command, args, { cwd: root, stdio: "ignore" });
    child.on("error", () => resolve(false));
    child.on("close", (code) => resolve(code === 0));
  });
  if (target.language === "python") return (await probe(target.python || "python3", tool.check)) ? null : tool;
  if (["javascript", "typescript"].includes(target.language)) return (await probe("npx", ["--no-install", "c8", "--version"])) ? null : tool;
  if (target.language === "rust") return (await probe("cargo", ["llvm-cov", "--version"])) ? null : tool;
  if (target.language === "kotlin") {
    const build = await readFile(path.join(root, "build.gradle.kts"), "utf8").catch(() => "");
    return build.includes("kover") ? null : tool;
  }
  return null;
}
// Run a native test command, showing its output (on stderr with --json) and
// keeping it. Go's JSON events are shown as the text they carry.
function spawned(command, args, cwd, env, goJson = false) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, env, stdio: ["ignore", "pipe", "pipe"] });
    const shown = options.json ? process.stderr : process.stdout;
    let output = "";
    let pending = "";
    child.stdout.on("data", (chunk) => {
      const text = chunk.toString();
      output += text;
      if (!goJson) return shown.write(text);
      pending += text;
      const lines = pending.split("\n");
      pending = lines.pop();
      for (const line of lines) {
        try { const event = JSON.parse(line); if (event.Output) shown.write(event.Output); }
        catch { shown.write(line + "\n"); }
      }
    });
    child.stderr.on("data", (chunk) => { output += chunk.toString(); process.stderr.write(chunk); });
    child.on("error", reject);
    child.on("close", (code) => resolve({ ok: code === 0, output }));
  });
}
async function readOptionalDirectory(folder) {
  try {
    return await readdir(folder);
  } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
}
async function main() {
  if (options['machine-bits'] !== undefined) {
    options.machineBits = Number(options['machine-bits']);
    if (![32,64].includes(options.machineBits)) throw new Error('machineBits must be 32 or 64');
  }
  if (!verb || ["help", "--help", "-h"].includes(verb)) {
    output(
      "LawSpec " + VERSION + "\nUsage: lawspec init --target <language> [--project <directory>] [--minify]\n       lawspec check | doctor | explain <unit>::<law> | generate\n       lawspec evidence [<unit> | <unit>::<declaration>]\n       lawspec test [--target <language>] [--fresh] [--seed <n>] [--update-recorded] [--tag <t>] [--exclude-tag <t>] [--report junit=<path>] [--coverage] [--benchmarks]\n       lawspec package [--project <package directory>]\n       lawspec examples [--example payments] [--target <language>] [--output <directory>]\nOptions: --config <path>, --target <language>, --machine-bits <32|64>, --json, --no-cache\nGeneration: --dry-run, --check, --minify\nTargets: " +
        targets.join(", "),
    );
    return;
  }
  if (verb === "--version") {
    output(VERSION);
    return;
  }
  if (positional.length > (["explain", "evidence"].includes(verb) ? 1 : 0))
    throw new Error(`Unexpected argument: ${positional.join(" ")}`);
  if (verb === "examples") {
    if (
      options.config ||
      options.project ||
      options["dry-run"] ||
      options.check
    )
      throw new Error("examples supports --example, --target, --output, --machine-bits, --json and --minify only");
    const result = await generateExamples(options);
    if (options.example) {
      output(options.json ? result : result.map(r =>
        `${r.target}: payment project in ${r.directory}; ${r.preservedAdapters.length} user files preserved.` +
        (r.adapterUpdates.length ? `\nReview changed example files: ${r.adapterUpdates.map(a => a.path).join(", ")}` : "")
      ).join("\n") + "\nOpen each project's README.md, run lawspec generate, then its native test command.");
      return;
    }
    output(
      options.json
        ? result
        : result
            .map(
              (r) =>
                `${r.target}: ${r.files.length} artifacts in ${r.directory}; ${r.preservedAdapters.length} user adapters preserved.${r.adapterUpdates.length ? "\nReview required adapter signatures:\n" + r.adapterUpdates.map((a) => a.path + "\n" + a.requiredAdapter).join("\n") : ""}`,
            )
            .join("\n") +
            "\nInspection artifacts only; native toolchains and dependencies are not checked. Stubs must be implemented before running tests.",
    );
    return;
  }
  if (options.output) throw new Error("--output is only supported by examples");
  if (options.example) throw new Error("--example is only supported by examples");
  if (options.minify && !["init", "generate", "examples", "test"].includes(verb))
    throw new Error("--minify applies to init, generate, test and examples");
  if ((options.fresh || options.seed !== undefined || options.tag || options["exclude-tag"] ||
      options.report !== undefined || options.coverage || options["update-recorded"] || options.benchmarks) && verb !== "test")
    throw new Error("--fresh, --seed, --update-recorded, --tag, --exclude-tag, --report, --coverage and --benchmarks apply to test");
  if (options.seed !== undefined && !/^[0-9]+$/.test(options.seed))
    throw new Error("--seed must be a whole number");
  if (verb === "init") return init();
  if (verb === "package") return packageCommand();
  if (!["check", "doctor", "evidence", "explain", "generate", "test"].includes(verb))
    throw new Error(`Unknown command: ${verb}`);
  const config = JSON.parse(await readFile(configFile, "utf8"));
  if (
    config.version !== 1 ||
    !Array.isArray(config.sources) ||
    !Array.isArray(config.targets)
  )
    throw new Error(
      "Expected lawspec.json version 1 with sources and targets arrays",
    );
  const selected = config.targets.filter(
    (t) => !options.target || t.language === options.target,
  );
  if (["doctor", "generate", "test"].includes(verb) && !selected.length)
    throw new Error("No matching configured target");
  const roots = selected.map((t) => path.resolve(configRoot, t.root));
  if (new Set(roots).size !== roots.length)
    throw new Error("Each configured target needs its own project root");
  if (verb === "doctor") {
    const reports = await Promise.all(
      selected.map((t, i) => doctor(t, roots[i])),
    );
    output(
      options.json
        ? reports
        : reports
            .map(
              (r) =>
                `${r.target}: ${r.ok ? "ready" : `${r.message}\n${r.instructions}`}`,
            )
            .join("\n"),
    );
    if (reports.some((r) => !r.ok)) process.exitCode = 1;
    return;
  }
  if (config.machineBits !== undefined && ![32, 64].includes(config.machineBits)) throw new Error("machineBits must be 32 or 64");
  if (config.cache !== undefined && typeof config.cache !== "boolean") throw new Error("cache must be true or false");
  const cache = await cacheDirectory(config);
  const input = {
    ...(cache === undefined ? {} : { cacheDirectory: cache }),
    sources: await sources(config),
    ...(await packageInput(config, configRoot)),
    generation: config.generation,
    machineBits: options.machineBits ?? config.machineBits ?? 64,
  };
  const compiler = await createCompiler();
  // Each obligation reports how it is discharged, strongest first.
  const statuses = [
    ["proved", "PROVED"],
    ["exhaustively-checked", "EXHAUSTIVELY CHECKED"],
    ["property-tested", "PROPERTY TESTED"],
    ["runtime-checked", "RUNTIME CHECKED"],
    ["default-handler", "DEFAULT HANDLER"],
    ["assumed", "ASSUMED / EXTERNAL"],
    // The harness plane: a law it marks as known to fail, a law whose last
    // run was flaky, and a law whose tests it skips.
    ["known-failing", "KNOWN FAILING"],
    ["flaky", "FLAKY"],
    ["skipped", "SKIPPED"],
  ];
  const evidenceSummary = (evidence) => {
    if (!evidence.length) return "";
    const count = (status) => evidence.filter((item) => item.status === status).length;
    // The harness statuses are counted only when a harness gives some.
    const shown = statuses.filter(([status], i) => i < 5 || count(status));
    return ` Evidence: ${shown.map(([status, label]) => `${count(status)} ${label.toLowerCase()}`).join(", ")}.`;
  };
  const obligationName = (item) => item.declaration.replace("::law::", "::");
  if (verb === "check") {
    const result = diagnostics(await compiler.check(input));
    for (const target of selected) {
      if (target.nativeBindings !== undefined)
        diagnostics(await compiler.check({...input, nativeBindings: target.nativeBindings}));
    }
    output(
      options.json
        ? result
        : `Checked ${result.laws.length} law(s).` + evidenceSummary(result.evidence ?? []),
    );
    return;
  }
  if (verb === "evidence") {
    const result = diagnostics(await compiler.check(input));
    let evidence = result.evidence;
    // Native bindings are configured per target; their obligations are added.
    for (const target of selected) {
      if (target.nativeBindings === undefined) continue;
      const bound = diagnostics(await compiler.check({...input, nativeBindings: target.nativeBindings}));
      evidence = evidence.concat(bound.evidence
        .filter((item) => ["binding", "codec", "generator", "native-function"].includes(item.stage))
        .map((item) => ({...item, target: target.language})));
    }
    evidence = evidence.filter((item) => !positional[0] ||
      obligationName(item) === positional[0] || item.owner === positional[0]);
    if (positional[0] && !evidence.length) throw new Error("No matching obligation");
    // The last run's outcome (lawspec test): a law that failed, then passed
    // on a retry, is flaky; what its generated cases covered is its adequacy.
    const runs = await lastRuns();
    evidence = evidence.map((item) => {
      const run = item.stage === "law" ? runs.get(item.declaration) : undefined;
      if (!run) return item;
      return { ...item, ...(run.adequacy ? { adequacy: run.adequacy } : {}),
        ...(run.flaky && ["property-tested", "exhaustively-checked"].includes(item.status)
          ? { status: "flaky", reason: `${item.reason}; its last run failed, then passed on a retry` } : {}) };
    });
    const harnessed = evidence.filter((item) => item.harness || item.adequacy);
    output(
      options.json
        ? evidence
        : [...statuses
            .map(([status, label]) => {
              const items = evidence.filter((item) => item.status === status);
              if (!items.length) return null;
              return `${label} (${items.length})\n` + items.map((item) =>
                `  ${item.stage} ${obligationName(item)}${item.target ? ` [${item.target}]` : ""}` +
                (item.claim ? `: ${item.claim.text}` : "") + `\n    ${item.reason}`).join("\n");
            })
            .filter((section) => section !== null),
          // How each law is discharged: the harness plane, apart from what
          // the laws say.
          ...(harnessed.length ? [`HARNESS (${harnessed.length})\n` + harnessed.map(harnessText).join("\n")] : [])]
            .join("\n\n"),
    );
    return;
  }
  if (verb === "explain") {
    const result = diagnostics(await compiler.expand(input));
    const indices = result.laws
      .map((e, i) => ({ e, i }))
      .filter(
        ({ e }) => !positional[0] || `${e.owner}::${e.name}` === positional[0],
      );
    if (!indices.length) throw new Error("No matching law");
    output(
      options.json
        ? indices.map(({ e, i }) => ({ ...e, expansion: result.expansions[i] }))
        : indices
            .map(
              ({ e, i }) =>
                `${e.owner}::${e.name}\n${e.trace.join("\n=> ")}\n=> ${result.expansions[i]}` +
                explainAbilities(e, result.expansions[i], result.units) + explainExamples(e),
            )
            .join("\n\n"),
    );
    return;
  }
  if (verb === "test") return runTests(compiler, input, selected, roots, config);
  if (options["dry-run"] && options.check)
    throw new Error("--dry-run and --check are mutually exclusive");
  const artifacts = [];
  for (const target of selected)
    artifacts.push(
      diagnostics(
        await compiler.planGeneration({
          ...input,
          target: target.language,
          sourceDir: target.sourceDir,
          testDir: target.testDir,
          nativeBindings: target.nativeBindings,
          minify: options.minify === true,
        }),
      ).files,
    );
  const reports = await Promise.all(
    selected.map((t, i) => doctor(t, roots[i], artifacts[i])),
  );
  const failed = reports.filter((r) => !r.ok);
  if (failed.length)
    throw new Error(
      failed
        .map((r) => `${r.target}: ${r.message}\n${r.instructions}`)
        .join("\n"),
    );
  const plans = await Promise.all(
    artifacts.map((files, i) => planWrites(roots[i], files)),
  );
  if (!options["dry-run"] && !options.check) await applyWrites(plans);
  const summary = plans.map((plan, i) => ({
    target: selected[i].language,
    changes: plan.changes.map((c) => ({ action: c.action, path: c.relative })),
    preservedAdapters: plan.preserved,
    adapterUpdates: plan.adapterUpdates,
    test: testCommand(selected[i], roots[i]),
  }));
  output(
    options.json
      ? summary
      : summary
          .map(
            (r) =>
              `${r.target}: ${r.changes.length} ${options["dry-run"] || options.check ? "planned" : "applied"} change(s), ${r.preservedAdapters.length} user adapter(s) preserved.${r.adapterUpdates.length ? "\nReview required adapter signatures:\n" + r.adapterUpdates.map((a) => a.path + "\n" + a.requiredAdapter).join("\n") : ""}\nTest: ${r.test}`,
          )
          .join("\n"),
  );
  if (options.check && plans.some((p) => p.changes.length))
    process.exitCode = 1;
}
main().catch(async (error) => {
  if (createdState !== null) await rm(createdState, { recursive: true, force: true });
  if (options.json)
    output({
      diagnostics: error.diagnostics || [
        { code: "cli", message: error.message, at: null },
      ],
    });
  else console.error(`lawspec: ${error.message}`);
  process.exitCode = 1;
});
