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

// The native invocations that run exactly the given laws' tests, each with
// the laws it covers and how to tell, from the runner's own report, which of
// them ran. Names are matched whole, so law1 never selects law10. `scratch`
// is a folder for reports.
export function invocations(target, entries, { offline = false, scratch = "." } = {}) {
  const language = target.language;
  const testDir = target.testDir;
  const relativeTo = (file, defaultDir) => {
    const directory = testDir || defaultDir;
    return file.startsWith(directory + "/") ? file.slice(directory.length + 1) : file;
  };
  const tests = (entry) => [`law${entry.index}Example*`, `law${entry.index}Boundary*`, `law${entry.index}Property*`];
  const kinds = (entry) => new RegExp(`^law${entry.index}(Example|Boundary|Property)`);
  const className = (file, defaultDir, extension) => without(relativeTo(file, defaultDir), extension).replaceAll("/", ".");
  if (language === "python")
    return groupBy(entries, (e) => e.file).map(([file, laws], n) => {
      const report = path.join(scratch, `pytest-${n}.xml`);
      return { laws, command: target.python || "python3",
        args: ["-m", "pytest", "-q", file, "-k", laws.map((e) => `test_law${e.index}_`).join(" or "), `--junitxml=${report}`],
        report: { kind: "junit", files: [report] },
        ran: (test) => laws.filter((e) => test.name.startsWith(`test_law${e.index}_`)) };
    });
  if (language === "javascript" || language === "typescript") {
    const pattern = (e) => `^${regex(e.label)}( example: .*| property)?$`;
    const files = [...new Set(entries.map((e) => language === "typescript"
      ? `dist/${without(e.file, ".ts")}.js` : e.file))];
    const report = path.join(scratch, "node.xml");
    const run = { laws: entries, command: process.execPath,
      args: ["--test", `--test-name-pattern=(${entries.map(pattern).join("|")})`,
        "--test-reporter=spec", "--test-reporter-destination=stdout",
        "--test-reporter=junit", `--test-reporter-destination=${report}`, ...files],
      report: { kind: "junit", files: [report] },
      ran: (test) => entries.filter((e) => new RegExp(pattern(e)).test(test.name)) };
    return language === "typescript"
      ? [{ laws: [], command: "npm", args: ["exec", "--", "tsc", "-p", "tsconfig.json"] }, run]
      : [run];
  }
  if (language === "go")
    return groupBy(entries, (e) => path.posix.dirname(e.file)).map(([directory, laws]) => ({
      laws, command: "go",
      args: ["test", "-json", "-count=1", `./${directory}`, "-run", `^TestLaw(${laws.map((e) => e.index).join("|")})(Example|Boundary|Property)`],
      report: { kind: "go-json" },
      ran: (test) => laws.filter((e) => new RegExp(`^TestLaw${e.index}(Example|Boundary|Property)`).test(test.name)) }));
  if (language === "java") {
    const byClass = groupBy(entries, (e) => className(e.file, "src/test/java", ".java"));
    return [{ laws: entries, command: target.maven || "mvn",
      args: [...(offline ? ["-o"] : []), "-B", "test", `-Dtest=${byClass.map(([name, laws]) => `${name}#${laws.flatMap(tests).join("+")}`).join(",")}`],
      report: { kind: "junit", directory: "target/surefire-reports" },
      ran: (test) => entries.filter((e) => test.classname === className(e.file, "src/test/java", ".java") && kinds(e).test(test.name)) }];
  }
  // Kotest names tests by string, which Gradle's method filters cannot
  // select. Kotest's own filter selects them within each class: one pattern,
  // matched against whole names, whose * becomes .*? (several comma-separated
  // patterns must all match, so alternatives go in one group).
  if (language === "kotlin")
    return groupBy(entries, (e) => e.file).map(([file, laws]) => {
      const filter = `(${laws.flatMap((e) => ["Example", "Boundary", "Property"].map((kind) => `law${e.index}${kind}`)).join("|")})*`;
      const name = className(file, "src/test/kotlin", ".kt");
      return { laws, command: target.gradle || "gradle",
        args: [...(offline ? ["--offline"] : []), "--console=plain", "test", "--rerun", "--tests", name],
        env: { "kotest.filter.tests": filter, kotest_filter_tests: filter },
        report: { kind: "junit", directory: "build/test-results/test" },
        ran: (test) => laws.filter((e) => test.classname === name && kinds(e).test(test.name)) };
    });
  if (language === "rust")
    return groupBy(entries, (e) => e.file).map(([file, laws]) => ({
      laws, command: "cargo",
      args: ["test", ...(offline ? ["--offline"] : []), "--test", path.posix.basename(file, ".rs"), "--", "--exact",
        ...laws.map((e) => `test_${e.index}`)],
      report: { kind: "lines", pattern: /^test (test_\d+) \.\.\. (ok|FAILED)/ },
      ran: (test) => laws.filter((e) => test.name === `test_${e.index}`) }));
  if (language === "haskell") {
    const module = (e) => without(relativeTo(e.file, "test"), "Spec.hs").replaceAll("/", ".");
    const matches = entries.flatMap((e) => ["Example", "Boundary", "Property"].map((kind) => `${module(e)}/law${e.index}${kind}`));
    return [{ laws: entries, command: "stack",
      args: ["--no-terminal", "test", "--test-arguments", matches.map((m) => `--match ${m}`).join(" ")],
      report: { kind: "hspec" },
      ran: (test) => entries.filter((e) => test.classname === module(e) && kinds(e).test(test.name)) }];
  }
  throw new Error(`lawspec test does not support ${language}`);
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
        return ["pass", "fail"].includes(event.Action) && event.Test ? [{ name: event.Test, classname: event.Package }] : [];
      } catch { return []; }
    });
  if (report?.kind === "lines")
    return output.split("\n").flatMap((line) => {
      const match = line.match(report.pattern);
      return match ? [{ name: match[1], classname: "" }] : [];
    });
  if (report?.kind === "hspec") {
    // hspec prints each module, then its examples indented beneath it.
    const tests = [];
    let module = "";
    for (const line of output.split("\n")) {
      if (/^\S/.test(line) && !/^(Finished|Failures|Randomized|\d+ examples?)/.test(line)) module = line.trim();
      const example = line.match(/^\s+(law\d+\S*?):?(?:\s.*)?\s\[[✔✘]\]\s*$/);
      if (example) tests.push({ name: example[1], classname: module });
    }
    return tests;
  }
  return [];
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
