// Generated from templates/npm/test-command.mjs by lawspec-dev generate. Do not edit.
// lawspec test: run the generated tests of the laws whose results may have
// changed since their last passing run, through each target's own runner.
//
// A law's result is keyed by everything it depends on: its plan key (the law
// and the Merkle digests of the types and definitions it reaches), the
// compiler build, the target's configuration, its unit's generated test file,
// the project's build and lock files, the toolchain the doctor reports and, for
// a law that calls adapters, every file in the target project that LawSpec
// did not generate. A passing run records each law's key and seed; a law runs
// again when its key changes or with --fresh.
import { createHash, randomUUID } from "node:crypto";
import { readdir, readFile, stat } from "node:fs/promises";
import path from "node:path";

// Folders that hold dependencies, build output or caches, not code under test.
const skipped = new Set([".git", ".lawspec", "node_modules", "dist", "build", "target", "out", ".gradle",
  ".stack-work", "_build", "deps", ".elixir_ls", "__pycache__", ".hypothesis", ".pytest_cache", ".venv", "venv", ".idea", ".vscode"]);
// Build and lock files, which choose the toolchain and dependencies.
const environmentFiles = ["package.json", "package-lock.json", "tsconfig.json", "pyproject.toml", "go.mod",
  "go.sum", "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
  "Cargo.toml", "Cargo.lock", "stack.yaml", "stack.yaml.lock", "package.yaml",
  "rebar.config", "rebar.config.script", "rebar.lock", "mix.exs", "mix.lock", "gleam.toml", "manifest.toml"];

const digest = (value) => createHash("sha256").update(value).digest("hex");
// The crypto builder owns these outputs. Inputs and other priv/ assets still
// contribute to the adapter digest; rebuilding the NIF cannot invalidate a pass.
const cryptoBuildOutput = (file) => /^priv\/lawspec_crypto_native\.(?:so|dll)(?:\.build|\.\d+\.tmp)?$/.test(file);

// Every file in a project that LawSpec did not generate, by content.
export async function projectDigest(root, generated) {
  const hash = createHash("sha256");
  async function walk(folder) {
    const entries = (await readdir(path.join(root, folder), { withFileTypes: true }))
      .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    for (const entry of entries) {
      const relative = folder ? `${folder}/${entry.name}` : entry.name;
      if (entry.isDirectory()) {
        if (!skipped.has(entry.name) && !relative.endsWith("testdata/rapid")) await walk(relative);
      } else if (entry.isFile() && !generated.has(relative) && !cryptoBuildOutput(relative)) {
        hash.update(relative + "\0").update(await readFile(path.join(root, relative))).update("\0");
      }
    }
  }
  await walk("");
  return hash.digest("hex");
}

export async function environmentDigest(root, report) {
  // Coverage locations describe build output; native tools can discover more
  // output directories after the first run. Build configuration is hashed below.
  const {coverage: _coverage, ...toolchain} = report ?? {};
  const parts = [JSON.stringify(report ? toolchain : null)];
  const names = (await readdir(root)).filter((name) => environmentFiles.includes(name) || name.endsWith(".cabal")).sort();
  for (const name of names) parts.push(name, await readFile(path.join(root, name), "utf8"));
  return digest(JSON.stringify(parts));
}

// Every recorded value under recorded/, by content: "" when there are none.
export async function recordedDigest(folder) {
  const hash = createHash("sha256");
  let any = false;
  async function walk(relative) {
    const entries = await readdir(path.join(folder, relative), { withFileTypes: true }).catch(() => []);
    for (const entry of entries.sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0))) {
      const next = relative ? `${relative}/${entry.name}` : entry.name;
      if (entry.isDirectory()) await walk(next);
      else if (entry.isFile()) {
        any = true;
        hash.update(next + "\0").update(await readFile(path.join(folder, next))).update("\0");
      }
    }
  }
  await walk("");
  return any ? hash.digest("hex") : "";
}

// The result key of each law in a target's test manifest.
export function lawKeys({ build, target, machineBits, minify, tests, files, environment, project }) {
  const contents = new Map(files.map((file) => [file.path, file.content]));
  const configuration = JSON.stringify({ ...target, root: undefined });
  return new Map(tests.map((entry) => [entry.law, digest(JSON.stringify([
    build, configuration, machineBits, minify, entry.key, digest(contents.get(entry.file) ?? ""),
    environment, entry.callsAdapters ? project : null,
  ]))]));
}

const regex = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const without = (file, extension) => file.slice(0, -extension.length);
const groupBy = (entries, key) => {
  const groups = new Map();
  for (const entry of entries) groups.set(key(entry), [...(groups.get(key(entry)) ?? []), entry]);
  return [...groups.entries()];
};

// Rebar and Mix run their configured compile hooks. Gleam has no corresponding
// hook, so build its generated crypto bridge before starting a native test VM.
export function preparationInvocations(target, files) {
  return target.language === "gleam" && files.some((file) => file.path === "priv/lawspec_crypto_native.c")
    ? [{command: "escript", args: ["lawspec_crypto_build.escript"]}]
    : [];
}

// The native invocations that run the harness's benchmarks (lawspec test
// --benchmarks): each target's test command, selecting the tests that
// measure them by the names the manifest gives (entry.name). Benchmarks are
// measured, never asserted; their timings reach the summary through the
// harness statistics.
export function benchmarkInvocations(target, entries, { offline = false } = {}) {
  if (!entries.length) return [];
  const language = target.language;
  const testDir = target.testDir;
  const relativeTo = (file, defaultDir) => {
    const directory = testDir || defaultDir;
    return file.startsWith(directory + "/") ? file.slice(directory.length + 1) : file;
  };
  const className = (file, defaultDir, extension) => without(relativeTo(file, defaultDir), extension).replaceAll("/", ".");
  if (language === "erlang")
    return entries.map((entry) => ({ command: "rebar3", args: ["eunit", "--generator",
      `${path.posix.basename(entry.file, ".erl")}:${entry.name}_cases`] }));
  if (language === "elixir")
    return groupBy(entries, (entry) => entry.file).map(([file, marks]) => ({ command: "mix",
      args: ["test", file, ...marks.flatMap((entry) => ["--only", `lawspec:${entry.name}`])] }));
  if (language === "gleam")
    return [{ command: "gleam", args: ["test", "--target", "erlang"], env: {
      LAWSPEC_BEAM_BENCHMARKS: JSON.stringify(entries.map((entry) => ({
        module: path.posix.basename(entry.file, ".gleam"), function: `${entry.name}__case_0_test`
      })))
    } }];
  if (language === "python")
    return groupBy(entries, (e) => e.file).map(([file, marks]) => ({ command: target.python || "python3",
      args: ["-m", "pytest", "-q", "-s", file, "-k", marks.map((e) => e.name).join(" or ")] }));
  if (language === "javascript" || language === "typescript") {
    const files = [...new Set(entries.map((e) => language === "typescript" ? `dist/${without(e.file, ".ts")}.js` : e.file))];
    const run = { command: process.execPath,
      args: ["--test", `--test-name-pattern=^(${entries.map((e) => regex(e.name)).join("|")})$`, ...files] };
    return language === "typescript" ? [{ command: "npm", args: ["exec", "--", "tsc", "-p", "tsconfig.json"] }, run] : [run];
  }
  if (language === "go")
    return groupBy(entries, (e) => path.posix.dirname(e.file)).map(([directory, marks]) => ({ command: "go",
      args: ["test", "-count=1", "-v", `./${directory}`, "-run", `^(${marks.map((e) => regex(e.name)).join("|")})$`] }));
  if (language === "java") {
    const byClass = groupBy(entries, (e) => className(e.file, "src/test/java", ".java"));
    return [{ command: target.maven || "mvn", args: [...(offline ? ["-o"] : []), "-B", "test",
      `-Dtest=${byClass.map(([name, marks]) => `${name}#${marks.map((e) => e.name).join("+")}`).join(",")}`] }];
  }
  if (language === "kotlin")
    return groupBy(entries, (e) => e.file).map(([file, marks]) => {
      const filter = `(${marks.map((e) => e.name).join("|")})`;
      return { command: target.gradle || "gradle",
        args: [...(offline ? ["--offline"] : []), "--console=plain", "test", "--rerun", "--tests", className(file, "src/test/kotlin", ".kt")],
        env: { "kotest.filter.tests": filter, kotest_filter_tests: filter } };
    });
  if (language === "rust")
    return groupBy(entries, (e) => e.file).map(([file, marks]) => ({ command: "cargo",
      args: ["test", ...(offline ? ["--offline"] : []), "--test", path.posix.basename(file, ".rs"), "--", "--exact", "--nocapture", ...marks.map((e) => e.name)] }));
  if (language === "haskell") {
    const module = (e) => without(relativeTo(e.file, "test"), "Spec.hs").replaceAll("/", ".");
    // hspec matches by substring, and a benchmark's name has spaces, so each
    // module's benchmarks are selected together.
    return [{ command: "stack", args: ["--no-terminal", "test", "--test-arguments",
      [...new Set(entries.map((e) => `--match ${module(e)}/benchmark`))].join(" ")] }];
  }
  throw new Error(`lawspec test does not support ${language}`);
}

// The native invocations that run exactly the given laws' tests, each with
// the laws it covers and how to tell, from the runner's own report, which of
// them ran. A law's tests are named after its label (entry.name, see
// LawSpec.TestNames), then a kind after a separator no name contains, so one
// law's name never selects another's. `scratch` is a folder for reports;
// `coverage` asks each runner to measure coverage too (see coverageSetup).
export function invocations(target, entries, { offline = false, scratch = ".", coverage = null, xdist = false,
  root = process.cwd(), coverageConfig } = {}) {
  if (!entries.length) return [];
  const language = target.language;
  const testDir = target.testDir;
  const relativeTo = (file, defaultDir) => {
    const directory = testDir || defaultDir;
    return file.startsWith(directory + "/") ? file.slice(directory.length + 1) : file;
  };
  const named = (entry) => new RegExp(`^${regex(entry.name)}_`);
  const className = (file, defaultDir, extension) => without(relativeTo(file, defaultDir), extension).replaceAll("/", ".");
  if (["erlang", "elixir", "gleam"].includes(language)) {
    const run = randomUUID();
    const file = path.join(scratch, `beam-${run}.jsonl`);
    const identity = (entry) => `${entry.unit}::${entry.name}`;
    const env = { LAWSPEC_BEAM_REPORT: file, LAWSPEC_BEAM_RUN: run };
    const measured = coverage ? {run, file: path.resolve(coverage, "runs", `${run}.coverdata`),
      ...(language === "elixir" ? {beamDirectory: coverageConfig?.compilePath} : {}),
      ...(language === "erlang" ? {tool: "rebar3"} : {}),
      ...(language === "gleam" ? {metadata: path.resolve(coverage, "runs", `${run}.json`)} : {})} : null;
    let command, args;
    if (language === "elixir") {
      command = "mix";
      args = ["test", ...new Set(entries.map((entry) => entry.file)),
        ...entries.flatMap((entry) => ["--only", `lawspec_identity:${identity(entry)}`])];
      if (measured) {
        if (coverageConfig?.tool !== "Mix.Tasks.Test.Coverage" || !coverageConfig.output || !coverageConfig.compilePath)
          throw new Error("BEAM coverage requires Mix.Tasks.Test.Coverage and its effective output directory from lawspec doctor");
        args.push("--cover", "--export-coverage",
          path.relative(path.resolve(root, coverageConfig.output), without(measured.file, ".coverdata")));
      }
      if (offline) env.HEX_OFFLINE = "1";
    } else {
      env.LAWSPEC_BEAM_LAWS = JSON.stringify(entries.map(({unit, name}) => ({unit, name})));
      if (language === "erlang") {
        command = "rebar3";
        args = ["eunit", "--generator", "lawspec_generated_tests:lawspec_test_"];
        if (measured) args.push("--cover", "--cover_export_name", without(measured.file, ".coverdata"));
      } else {
        command = "gleam";
        args = ["test", "--target", "erlang"];
        if (measured) env.LAWSPEC_BEAM_COVERAGE = JSON.stringify(measured);
      }
    }
    return [{ laws: entries, command, args, env, ...(measured ? {coverage: measured} : {}), report: {kind: "beam-events", file, run},
      ran: (test) => test.status === "passed" ? entries.filter((entry) => test.identity === identity(entry)) : [] }];
  }
  if (language === "python")
    return groupBy(entries, (e) => e.file).map(([file, laws], n) => {
      const report = path.join(scratch, `pytest-${n}.xml`);
      // parallel: pytest-xdist runs the tests on several workers, when it
      // is installed (lawspec test checks); otherwise one after another.
      const workers = xdist && laws.some((e) => e.parallel) ? ["-p", "xdist", "-n", "auto"] : [];
      const pytest = ["-m", "pytest", "-q", ...workers, file, "-k", laws.map((e) => `${e.name}__`).join(" or "), `--junitxml=${report}`];
      return { laws, command: target.python || "python3",
        args: coverage ? ["-m", "coverage", "run", "--append", `--data-file=${path.join(coverage, ".coverage")}`, ...pytest.slice(1)] : pytest,
        report: { kind: "junit", files: [report] },
        ran: (test) => laws.filter((e) => test.name.startsWith(`${e.name}__`)) };
    });
  if (language === "javascript" || language === "typescript") {
    const pattern = (e) => `^${regex(e.label)}( example: .*| property| known failing| skipped| replay| search)?$`;
    const files = [...new Set(entries.map((e) => language === "typescript"
      ? `dist/${without(e.file, ".ts")}.js` : e.file))];
    const report = path.join(scratch, "node.xml");
    // parallel: test files run at the same time too.
    const node = ["--test", ...(entries.some((e) => e.parallel) ? ["--test-concurrency=" + Math.max(2, (globalThis.navigator?.hardwareConcurrency ?? 2))] : []),
      `--test-name-pattern=(${entries.map(pattern).join("|")})`,
      "--test-reporter=spec", "--test-reporter-destination=stdout",
      "--test-reporter=junit", `--test-reporter-destination=${report}`, ...files];
    const run = { laws: entries, command: coverage ? "npx" : process.execPath,
      args: coverage ? ["--no-install", "c8", "--reporter=text", `--reports-dir=${coverage}`, process.execPath, ...node] : node,
      report: { kind: "junit", files: [report] },
      ran: (test) => entries.filter((e) => new RegExp(pattern(e)).test(test.name)) };
    return language === "typescript"
      ? [{ laws: [], command: "npm", args: ["exec", "--", "tsc", "-p", "tsconfig.json"] }, run]
      : [run];
  }
  if (language === "go")
    return groupBy(entries, (e) => path.posix.dirname(e.file)).map(([directory, laws]) => ({
      laws, command: "go",
      args: ["test", "-json", "-count=1", ...(coverage ? ["-cover", `-coverprofile=${path.join(coverage, `go-${directory.replaceAll("/", "_") || "root"}.out`)}`] : []),
        `./${directory}`, "-run", `^(${laws.map((e) => regex(e.name)).join("|")})_`],
      report: { kind: "go-json" },
      ran: (test) => laws.filter((e) => named(e).test(test.name)) }));
  if (language === "java") {
    const byClass = groupBy(entries, (e) => className(e.file, "src/test/java", ".java"));
    return [{ laws: entries, command: target.maven || "mvn",
      args: [...(offline ? ["-o"] : []), "-B", ...(coverage ? ["org.jacoco:jacoco-maven-plugin:prepare-agent"] : []), "test",
        ...(coverage ? ["org.jacoco:jacoco-maven-plugin:report"] : []),
        `-Dtest=${byClass.map(([name, laws]) => `${name}#${laws.map((e) => `${e.name}_*`).join("+")}`).join(",")}`],
      report: { kind: "junit", directory: "target/surefire-reports" },
      ran: (test) => entries.filter((e) => test.classname === className(e.file, "src/test/java", ".java") && named(e).test(test.name)) }];
  }
  // Kotest names tests by string, which Gradle's method filters cannot
  // select. Kotest's own filter selects them within each class: one pattern,
  // matched against whole names, whose * becomes .*? (several comma-separated
  // patterns must all match, so alternatives go in one group).
  if (language === "kotlin")
    return groupBy(entries, (e) => e.file).map(([file, laws]) => {
      const filter = `(${laws.map((e) => `${e.name}_`).join("|")})*`;
      const name = className(file, "src/test/kotlin", ".kt");
      return { laws, command: target.gradle || "gradle",
        args: [...(offline ? ["--offline"] : []), "--console=plain", "test", ...(coverage ? ["koverXmlReport"] : []), "--rerun", "--tests", name],
        env: { "kotest.filter.tests": filter, kotest_filter_tests: filter },
        report: { kind: "junit", directory: "build/test-results/test" },
        ran: (test) => laws.filter((e) => test.classname === name && named(e).test(test.name)) };
    });
  if (language === "rust")
    return groupBy(entries, (e) => e.file).map(([file, laws]) => ({
      laws, command: "cargo",
      args: [...(coverage ? ["llvm-cov", "--no-report"] : []), "test", ...(offline ? ["--offline"] : []), "--test", path.posix.basename(file, ".rs"), "--", "--exact",
        ...laws.map((e) => e.name)],
      report: { kind: "lines", pattern: /^test (\S+) \.\.\. (ok|FAILED|ignored)/ },
      ran: (test) => laws.filter((e) => test.name === e.name) }));
  if (language === "haskell") {
    const module = (e) => without(relativeTo(e.file, "test"), "Spec.hs").replaceAll("/", ".");
    const matches = entries.map((e) => `${module(e)}/${e.name}_`);
    return [{ laws: entries, command: "stack",
      args: ["--no-terminal", "test", ...(coverage ? ["--coverage"] : []), "--test-arguments", matches.map((m) => `--match ${m}`).join(" ")],
      report: { kind: "hspec" },
      ran: (test) => entries.filter((e) => test.classname === module(e) && named(e).test(test.name)) }];
  }
  throw new Error(`lawspec test does not support ${language}`);
}

// What --coverage needs on each target, and how to say it is missing.
export const coverageTools = {
  erlang: { tool: "OTP cover", install: "install Erlang/OTP with the tools application" },
  elixir: { tool: "OTP cover", install: "install Erlang/OTP with the tools application" },
  gleam: { tool: "OTP cover", install: "install Erlang/OTP with the tools application" },
  python: { tool: "coverage.py", check: ["-c", "import coverage"], install: "python -m pip install coverage" },
  javascript: { tool: "c8", install: "npm install --save-dev c8" },
  typescript: { tool: "c8", install: "npm install --save-dev c8" },
  go: { tool: "go test -cover", install: "(built in)" },
  java: { tool: "JaCoCo", install: "(resolved by Maven as org.jacoco:jacoco-maven-plugin)" },
  kotlin: { tool: "Kover", install: "add id(\"org.jetbrains.kotlinx.kover\") to the plugins of build.gradle.kts" },
  rust: { tool: "cargo-llvm-cov", install: "cargo install cargo-llvm-cov" },
  haskell: { tool: "hpc", install: "(built into GHC; stack test --coverage)" },
};

// Laws selected by tag: every --tag, and none of --exclude-tag.
export function selectByTags(entries, include = [], exclude = []) {
  return entries.filter((e) => (!include.length || include.some((t) => (e.tags ?? []).includes(t))) &&
    !exclude.some((t) => (e.tags ?? []).includes(t)));
}

// A recorded failure takes precedence over any older passing cache entry,
// including when an adapter is repaired by restoring its previous contents.
export function testsToRun(entries, keys, previous, failures, {fresh = false, coverage = false, updateRecorded = false} = {}) {
  return entries.filter((entry) => fresh || coverage || updateRecorded || failures[entry.law] ||
    previous[entry.law]?.key !== keys.get(entry.law));
}

// Read complete outer elements, preserving nested suites and native payloads.
// Comments and CDATA can contain apparent XML tags; they are never elements.
function junitElements(xml, names) {
  const elements = [];
  let current;
  const tags = /<!--[\s\S]*?-->|<!\[CDATA\[[\s\S]*?\]\]>|<\?[\s\S]*?\?>|<(\/?)([A-Za-z_][\w:.-]*)(?:[^"'<>]|"[^"]*"|'[^']*')*>/g;
  for (const tag of xml.matchAll(tags)) {
    const [, closing, name] = tag;
    if (!name || !names.includes(name)) continue;
    const empty = /\/\s*>$/.test(tag[0]);
    if (!current) {
      if (closing) continue;
      current = {name, start: tag.index, opening: tag[0], depth: 0};
    }
    if (name !== current.name) continue;
    current.depth += closing ? -1 : empty ? 0 : 1;
    if (current.depth === 0) {
      elements.push({...current, xml: xml.slice(current.start, tag.index + tag[0].length)});
      current = undefined;
    }
  }
  return elements;
}

function junitCounts(cases) {
  const statuses = cases.map(test => new Set(junitElements(test.xml, ["failure", "error", "skipped"]).map(e => e.name)));
  return {tests: cases.length, ...Object.fromEntries(["failure", "error", "skipped"].map(name =>
    [name === "skipped" ? name : `${name}s`, statuses.filter(status => status.has(name)).length]))};
}

// One JUnit report from every target's: each target's suites, renamed with
// the target, in one <testsuites>.
export function mergeJunit(reports) {
  const suites = [];
  const totals = {tests: 0, failures: 0, errors: 0, skipped: 0};
  for (const { target, xml } of reports) {
    const elements = junitElements(xml, ["testsuite", "testcase"]);
    const found = elements.filter(e => e.name === "testsuite");
    // Node's native JUnit reporter puts top-level tests directly in testsuites.
    // Keep those cases (and their native failure payloads) instead of silently
    // dropping them because they have no intervening testsuite element.
    const loose = elements.filter(e => e.name === "testcase");
    if (loose.length) {
      const opening = `<testsuite name="native" ${Object.entries(junitCounts(loose)).map(([key, value]) => `${key}="${value}"`).join(" ")}>`;
      found.push({opening, xml: opening + "\n" + loose.map(e => e.xml).join("\n") + "\n</testsuite>"});
    }
    for (const suite of found) {
      const attributes = [...suite.opening.matchAll(/\s([A-Za-z_:][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)];
      const values = Object.fromEntries(attributes.map(match => [match[1], match[2] ?? match[3]]));
      const counts = junitCounts(junitElements(suite.xml, ["testcase"]));
      for (const key of Object.keys(totals))
        totals[key] += /^\d+$/.test(values[key] ?? "") ? Number(values[key]) : counts[key];
      const name = attributes.find(match => match[1] === "name");
      const opening = name
        ? suite.opening.slice(0, name.index) + ` name="${escapeXml(target)}: ${values.name.replaceAll('"', '&quot;')}"` + suite.opening.slice(name.index + name[0].length)
        : suite.opening.replace(/^<testsuite\b/, `<testsuite name="${escapeXml(target)}"`);
      suites.push(opening + suite.xml.slice(suite.opening.length));
    }
  }
  return `<?xml version="1.0" encoding="UTF-8"?>\n<testsuites tests="${totals.tests}" failures="${totals.failures}" errors="${totals.errors}" skipped="${totals.skipped}">\n` +
    suites.join("\n") + "\n</testsuites>\n";
}

const escapeXml = (text) => text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;").replaceAll('"', "&quot;");

// The harness statistics a run wrote (LAWSPEC_STATS): cover results, label
// counts, flaky and known-failing outcomes, benchmarks.
export async function harnessStatistics(directory) {
  const names = await readdir(directory).catch(() => []);
  const entries = [];
  for (const name of names.filter((n) => n.endsWith(".json")).sort())
    try { entries.push(JSON.parse(await readFile(path.join(directory, name), "utf8"))); } catch { /* partial */ }
  return entries;
}

// The tests a run executed, as {name, classname}, from the runner's report or
// output. Skipped tests are not counted.
export async function executedTests(report, output, root, since) {
  if (report?.kind === "beam-events") {
    // A native listener seals the invocation after its final event. Missing,
    // stale, malformed or interrupted reports are not execution evidence.
    const raw = await readFile(path.resolve(root, report.file), "utf8").catch(() => "");
    let rows;
    try { rows = raw.trim().split("\n").map((line) => JSON.parse(line)); } catch { return []; }
    if (rows.length < 2 || rows[0]?.event !== "start" || rows.at(-1)?.event !== "end" ||
      rows.some((row) => row?.run !== report.run)) return [];
    const tests = rows.slice(1, -1);
    if (tests.some((row) => row.event !== "test" || !["passed", "failed"].includes(row.status) ||
      typeof row.name !== "string" || typeof row.classname !== "string" || typeof row.identity !== "string" ||
      !Number.isFinite(row.time) || row.time < 0)) return [];
    return tests;
  }
  if (report?.kind === "junit") {
    const files = report.files ?? await reportFiles(path.join(root, report.directory), since);
    const tests = [];
    for (const file of files) {
      const xml = await readFile(path.resolve(root, file), "utf8").catch(() => "");
      for (const match of xml.matchAll(/<testcase\b([^>]*?)(\/>|>([\s\S]*?)<\/testcase>)/g)) {
        if (/<skipped\b/.test(match[3] ?? "")) continue;
        const attribute = (name) => unescapeXml(match[1].match(new RegExp(`\\b${name}="([^"]*)"`))?.[1] ?? "");
        tests.push({ name: attribute("name").replace(/\(\)$/, ""), classname: attribute("classname") });
      }
    }
    return tests;
  }
  if (report?.kind === "go-json")
    return output.split("\n").flatMap((line) => {
      try {
        const event = JSON.parse(line);
        return ["pass", "fail"].includes(event.Action) && event.Test
          ? [{ name: event.Test, classname: event.Package, status: event.Action === "pass" ? "passed" : "failed" }] : [];
      } catch { return []; }
    });
  if (report?.kind === "lines")
    return output.split("\n").flatMap((line) => {
      const match = line.match(report.pattern);
      return match && match[2] !== "ignored" ? [{ name: match[1], classname: "", status: match[2] === "ok" ? "passed" : "failed" }] : [];
    });
  if (report?.kind === "hspec") {
    // hspec prints each module, then its examples indented beneath it.
    const tests = [];
    let module = "";
    for (const line of output.split("\n")) {
      if (/^\S/.test(line) && !/^(Finished|Failures|Randomized|\d+ examples?)/.test(line)) module = line.trim();
      const example = line.match(/^\s+(law\S*?):?(?:\s.*)?\s\[([✔✘])\]\s*$/);
      if (example) tests.push({ name: example[1], classname: module, status: example[2] === "✔" ? "passed" : "failed" });
    }
    return tests;
  }
  return [];
}

// JUnit XML for a runner that writes none, from the tests it printed.
export function junitFromTests(tests) {
  const failures = tests.filter((t) => t.status === "failed").length;
  const skipped = tests.filter((t) => t.status === "skipped").length;
  // A BEAM scheduler wraps native functions from several units. Its module
  // is not the declaring class: retain the unit from the validated identity.
  const classname = (test) => {
    const separator = typeof test.identity === "string" ? test.identity.lastIndexOf("::") : -1;
    return separator > 0 ? test.identity.slice(0, separator) : test.classname ?? "";
  };
  return `<testsuite name="lawspec" tests="${tests.length}" failures="${failures}"${skipped ? ` skipped="${skipped}"` : ""}>\n` +
    tests.map((t) => `  <testcase classname="${escapeXml(classname(t))}" name="${escapeXml(t.name)}"` +
      (Number.isFinite(t.time) ? ` time="${t.time}"` : "") +
      (t.status === "failed" ? `><failure message="${escapeXml(t.failure ?? "failed")}"/></testcase>` :
        t.status === "skipped" ? `><skipped message="${escapeXml(t.reason ?? "skipped")}"/></testcase>` : "/>")).join("\n") + "\n</testsuite>";
}

async function reportFiles(directory, since) {
  const names = await readdir(directory).catch(() => []);
  const files = [];
  for (const name of names.filter((n) => n.endsWith(".xml"))) {
    const info = await stat(path.join(directory, name));
    if (info.mtimeMs >= since) files.push(path.join(directory, name));
  }
  return files;
}

const unescapeXml = (text) => text.replaceAll("&lt;", "<").replaceAll("&gt;", ">").replaceAll("&quot;", '"')
  .replaceAll("&apos;", "'").replaceAll("&#39;", "'").replaceAll("&amp;", "&");
