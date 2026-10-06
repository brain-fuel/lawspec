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
import { createHash } from "node:crypto";
import { readdir, readFile, stat } from "node:fs/promises";
import path from "node:path";

// Folders that hold dependencies, build output or caches, not code under test.
const skipped = new Set([".git", ".lawspec", "node_modules", "dist", "build", "target", "out", ".gradle",
  ".stack-work", "__pycache__", ".hypothesis", ".pytest_cache", ".venv", "venv", ".idea", ".vscode"]);
// Build and lock files, which choose the toolchain and dependencies.
const environmentFiles = ["package.json", "package-lock.json", "tsconfig.json", "pyproject.toml", "go.mod",
  "go.sum", "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
  "Cargo.toml", "Cargo.lock", "stack.yaml", "stack.yaml.lock", "package.yaml"];

const digest = (value) => createHash("sha256").update(value).digest("hex");

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
      } else if (entry.isFile() && !generated.has(relative)) {
        hash.update(relative + "\0").update(await readFile(path.join(root, relative))).update("\0");
      }
    }
  }
  await walk("");
  return hash.digest("hex");
}

export async function environmentDigest(root, report) {
  const parts = [JSON.stringify(report ?? null)];
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
export function invocations(target, entries, { offline = false, scratch = ".", coverage = null, xdist = false } = {}) {
  const language = target.language;
  const testDir = target.testDir;
  const relativeTo = (file, defaultDir) => {
    const directory = testDir || defaultDir;
    return file.startsWith(directory + "/") ? file.slice(directory.length + 1) : file;
  };
  const named = (entry) => new RegExp(`^${regex(entry.name)}_`);
  const className = (file, defaultDir, extension) => without(relativeTo(file, defaultDir), extension).replaceAll("/", ".");
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
    const node = ["--test", `--test-name-pattern=(${entries.map(pattern).join("|")})`,
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

// One JUnit report from every target's: each target's suites, renamed with
// the target, in one <testsuites>.
export function mergeJunit(reports) {
  const suites = [];
  for (const { target, xml } of reports) {
    const found = [...xml.matchAll(/<testsuite\b[\s\S]*?<\/testsuite>|<testsuite\b[^>]*\/>/g)].map((m) => m[0]);
    for (const suite of found)
      suites.push(suite.replace(/<testsuite\b([^>]*?)\bname="([^"]*)"/, (whole, before, name) => `<testsuite${before}name="${escapeXml(target)}: ${name}"`)
        .replace(/^<testsuite\b(?![^>]*\bname=)/, `<testsuite name="${escapeXml(target)}"`));
  }
  const count = (attribute) => suites.reduce((n, suite) => n + Number(suite.match(new RegExp(`\\b${attribute}="(\\d+)"`))?.[1] ?? 0), 0);
  return `<?xml version="1.0" encoding="UTF-8"?>\n<testsuites tests="${count("tests")}" failures="${count("failures")}" errors="${count("errors")}" skipped="${count("skipped")}">\n` +
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
  return `<testsuite name="lawspec" tests="${tests.length}" failures="${failures}">\n` +
    tests.map((t) => `  <testcase classname="${escapeXml(t.classname ?? "")}" name="${escapeXml(t.name)}"` +
      (t.status === "failed" ? `><failure message="failed"/></testcase>` : "/>")).join("\n") + "\n</testsuite>";
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
