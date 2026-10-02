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
import { readdir, readFile } from "node:fs/promises";
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
// the laws it covers. Names are matched whole, so law1 never selects law10.
export function invocations(target, entries, { offline = false } = {}) {
  const language = target.language;
  const testDir = target.testDir;
  const relativeTo = (file, defaultDir) => {
    const directory = testDir || defaultDir;
    return file.startsWith(directory + "/") ? file.slice(directory.length + 1) : file;
  };
  const tests = (entry) => [`law${entry.index}Example*`, `law${entry.index}Boundary*`, `law${entry.index}Property*`];
  if (language === "python")
    return groupBy(entries, (e) => e.file).map(([file, laws]) => ({
      laws, command: target.python || "python3",
      args: ["-m", "pytest", "-q", file, "-k", laws.map((e) => `test_law${e.index}_`).join(" or ")],
    }));
  if (language === "javascript" || language === "typescript") {
    const pattern = `^(${entries.map((e) => regex(e.label)).join("|")})( example: .*| property)?$`;
    const files = [...new Set(entries.map((e) => language === "typescript"
      ? `dist/${without(e.file, ".ts")}.js` : e.file))];
    const run = { laws: entries, command: process.execPath, args: ["--test", `--test-name-pattern=${pattern}`, ...files] };
    return language === "typescript"
      ? [{ laws: [], command: "npm", args: ["exec", "--", "tsc", "-p", "tsconfig.json"] }, run]
      : [run];
  }
  if (language === "go")
    return groupBy(entries, (e) => path.posix.dirname(e.file)).map(([directory, laws]) => ({
      laws, command: "go",
      args: ["test", "-count=1", `./${directory}`, "-run", `^TestLaw(${laws.map((e) => e.index).join("|")})(Example|Boundary|Property)`],
    }));
  if (language === "java") {
    const selection = groupBy(entries, (e) => e.file).map(([file, laws]) =>
      `${without(relativeTo(file, "src/test/java"), ".java").replaceAll("/", ".")}#${laws.flatMap(tests).join("+")}`);
    return [{ laws: entries, command: target.maven || "mvn",
      args: [...(offline ? ["-o"] : []), "-B", "test", `-Dtest=${selection.join(",")}`] }];
  }
  // Kotest names tests by string, which Gradle's method filters cannot
  // select. Kotest's own filter selects them within each class: one pattern,
  // matched against whole names, whose * becomes .*? (several comma-separated
  // patterns must all match, so alternatives go in one group).
  if (language === "kotlin")
    return groupBy(entries, (e) => e.file).map(([file, laws]) => {
      const filter = `(${laws.flatMap((e) => ["Example", "Boundary", "Property"].map((kind) => `law${e.index}${kind}`)).join("|")})*`;
      return { laws, command: target.gradle || "gradle",
        args: [...(offline ? ["--offline"] : []), "--console=plain", "test", "--rerun",
          "--tests", without(relativeTo(file, "src/test/kotlin"), ".kt").replaceAll("/", ".")],
        env: { "kotest.filter.tests": filter, kotest_filter_tests: filter } };
    });
  if (language === "rust")
    return groupBy(entries, (e) => e.file).map(([file, laws]) => ({
      laws, command: "cargo",
      args: ["test", ...(offline ? ["--offline"] : []), "--test", path.posix.basename(file, ".rs"), "--", "--exact",
        ...laws.map((e) => `test_${e.index}`)],
    }));
  if (language === "haskell") {
    const matches = entries.flatMap((entry) => {
      const module = without(relativeTo(entry.file, "test"), "Spec.hs").replaceAll("/", ".");
      return ["Example", "Boundary", "Property"].map((kind) => `${module}/law${entry.index}${kind}`);
    });
    return [{ laws: entries, command: "stack",
      args: ["--no-terminal", "test", "--test-arguments", matches.map((m) => `--match ${m}`).join(" ")] }];
  }
  throw new Error(`lawspec test does not support ${language}`);
}
