#!/usr/bin/env node
import { readFile, mkdir, readdir, rm, stat, writeFile } from "node:fs/promises";
import { createHash } from "node:crypto";
import path from "node:path";
import { createCompiler } from "../api.mjs";
import { targets, templates, commands, setup } from "../templates.mjs";
import { generateExamples } from "../examples-command.mjs";
import { showScalar } from "../scalars.mjs";
import { doctor } from "../doctor.mjs";
import { spawn } from "node:child_process";
import { environmentDigest, executedTests, invocations, lawKeys, projectDigest } from "../test-command.mjs";
import {
  readOptional,
  planWrites,
  applyWrites,
  atomicWrite,
  safePath,
} from "../files.mjs";
const VERSION = /*@ version @*/;
const args = process.argv.slice(2);
const verb = args.shift();
const options = {};
const positional = [];
for (let i = 0; i < args.length; i++) {
  const arg = args[i];
  if (["--target", "--project", "--config", "--output", "--machine-bits", "--example", "--seed"].includes(arg)) {
    if (!args[i + 1] || args[i + 1].startsWith("--"))
      throw new Error(`Missing value for ${arg}`);
    options[arg.slice(2)] = args[++i];
  } else if (["--dry-run", "--check", "--json", "--minify", "--no-cache", "--fresh"].includes(arg))
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
  const units = result.units.map((u) => u.id).filter((u) => u !== "prelude");
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
// and record each passing law's key and seed (see test-command.mjs).
async function runTests(compiler, input, selected, roots, config) {
  const seed = options.seed ?? String(1 + Math.floor(Math.random() * 2147483646));
  const offline = process.env.LAWSPEC_OFFLINE === "1";
  const build = await buildDigest();
  const summaries = [];
  for (const [i, target] of selected.entries()) {
    const root = roots[i];
    const planned = diagnostics(await compiler.planGeneration({
      ...input, target: target.language, sourceDir: target.sourceDir, testDir: target.testDir,
      nativeBindings: target.nativeBindings, minify: options.minify === true,
    }));
    const pending = await planWrites(root, planned.files);
    if (pending.changes.length)
      throw new Error(`${target.language}: generated files are out of date; run lawspec generate${options.minify ? " --minify" : ""}`);
    const report = await doctor(target, root, planned.files);
    if (!report.ok) throw new Error(`${target.language}: ${report.message}\n${report.instructions}`);
    const generated = new Set(planned.files.filter((f) => f.ownership === "generated").map((f) => f.path));
    const keys = lawKeys({
      build, target, machineBits: input.machineBits, minify: options.minify === true,
      tests: planned.tests, files: planned.files,
      environment: await environmentDigest(root, report),
      project: await projectDigest(root, generated),
    });
    const resultsFile = path.join(configRoot, ".lawspec", "results",
      `${target.language}-${createHash("sha256").update(root).digest("hex").slice(0, 12)}.json`);
    const previous = JSON.parse((await readOptional(resultsFile)) ?? '{"version":1,"laws":{}}');
    const stale = planned.tests.filter((entry) => options.fresh || previous.laws[entry.law]?.key !== keys.get(entry.law));
    const passed = [];
    const unrun = [];
    let failed = false;
    const scratch = path.join(configRoot, ".lawspec", "reports", target.language);
    await rm(scratch, { recursive: true, force: true });
    await mkdir(scratch, { recursive: true });
    await writeFile(path.join(path.dirname(scratch), ".gitignore"), "*\n");
    for (const run of stale.length ? invocations(target, stale, { offline, scratch }) : []) {
      const since = Date.now() - 1000;
      const { ok, output } = await spawned(run.command, run.args, root,
        { ...process.env, ...run.env, LAWSPEC_SEED: seed, HSPEC_SEED: seed }, run.report?.kind === "go-json");
      if (!ok) { failed = true; break; }
      // A runner whose filter matched nothing reports success, so a law
      // counts as passed only if the runner's report shows its tests ran.
      const executed = new Set((await executedTests(run.report, output, root, since)).flatMap(run.ran ?? (() => [])));
      passed.push(...run.laws.filter((law) => executed.has(law)));
      unrun.push(...run.laws.filter((law) => !executed.has(law)));
    }
    if (unrun.length) failed = true;
    const laws = Object.fromEntries(planned.tests.filter((entry) => previous.laws[entry.law]).map((entry) => [entry.law, previous.laws[entry.law]]));
    for (const entry of passed) laws[entry.law] = { key: keys.get(entry.law), seed: Number(seed), passed: new Date().toISOString() };
    await mkdir(path.dirname(resultsFile), { recursive: true });
    await writeFile(path.join(path.dirname(resultsFile), ".gitignore"), "*\n");
    await writeFile(resultsFile, JSON.stringify({ version: 1, laws }, null, 2) + "\n");
    summaries.push({ target: target.language, seed: Number(seed), ran: stale.map((e) => e.law),
      unchanged: planned.tests.length - stale.length, ok: !failed,
      ...(unrun.length ? { unrun: unrun.map((e) => e.law) } : {}) });
  }
  output(options.json ? summaries : summaries.map((s) =>
    `${s.target}: ${s.ran.length ? `ran ${s.ran.length} law(s) with seed ${s.seed}` : "nothing to run"}` +
    `, ${s.unchanged} unchanged since their last passing run.${s.ok ? "" : " FAILED"}` +
    (s.unrun ? `\nNo tests ran for ${s.unrun.join(", ")}; the runner matched none of their tests.` : "")).join("\n"));
  if (summaries.some((s) => !s.ok)) process.exitCode = 1;
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
      "LawSpec " + VERSION + "\nUsage: lawspec init --target <language> [--project <directory>] [--minify]\n       lawspec check | doctor | explain <unit>::<law> | generate\n       lawspec evidence [<unit> | <unit>::<declaration>]\n       lawspec test [--target <language>] [--fresh] [--seed <n>]\n       lawspec package [--project <package directory>]\n       lawspec examples [--example payments] [--target <language>] [--output <directory>]\nOptions: --config <path>, --target <language>, --machine-bits <32|64>, --json, --no-cache\nGeneration: --dry-run, --check, --minify\nTargets: " +
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
  if ((options.fresh || options.seed !== undefined) && verb !== "test")
    throw new Error("--fresh and --seed apply to test");
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
  ];
  const evidenceSummary = (evidence) => {
    if (!evidence.length) return "";
    const count = (status) => evidence.filter((item) => item.status === status).length;
    return ` Evidence: ${statuses.map(([status, label]) => `${count(status)} ${label.toLowerCase()}`).join(", ")}.`;
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
    output(
      options.json
        ? evidence
        : statuses
            .map(([status, label]) => {
              const items = evidence.filter((item) => item.status === status);
              if (!items.length) return null;
              return `${label} (${items.length})\n` + items.map((item) =>
                `  ${item.stage} ${obligationName(item)}${item.target ? ` [${item.target}]` : ""}` +
                (item.claim ? `: ${item.claim.text}` : "") + `\n    ${item.reason}`).join("\n");
            })
            .filter((section) => section !== null)
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
