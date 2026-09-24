#!/usr/bin/env node
import { readFile, mkdir, readdir, stat } from "node:fs/promises";
import path from "node:path";
import { createCompiler } from "../api.mjs";
import { targets, templates, commands, setup } from "../templates.mjs";
import { doctor } from "../doctor.mjs";
import {
  readOptional,
  planWrites,
  applyWrites,
  atomicWrite,
  safePath,
} from "../files.mjs";
const args = process.argv.slice(2);
const verb = args.shift();
const options = {};
const positional = [];
for (let i = 0; i < args.length; i++) {
  const arg = args[i];
  if (["--target", "--project", "--config"].includes(arg)) {
    if (!args[i + 1] || args[i + 1].startsWith("--"))
      throw new Error(`Missing value for ${arg}`);
    options[arg.slice(2)] = args[++i];
  } else if (["--dry-run", "--check", "--json"].includes(arg))
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
  const files = [];
  async function visit(file) {
    const info = await stat(file);
    if (info.isDirectory())
      for (const entry of (await readdir(file)).sort())
        await visit(path.join(file, entry));
    else if (file.endsWith(".lawspec")) files.push(file);
  }
  for (const source of config.sources)
    await visit(path.resolve(configRoot, source));
  if (!files.length) throw new Error("No .lawspec source files found");
  return Promise.all(
    [...new Set(files)].sort().map(async (file) => ({
      path: path.relative(configRoot, file).split(path.sep).join("/"),
      content: await readFile(file, "utf8"),
    })),
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
  const additions = hasBuild ? {} : templates(language);
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
  config.targets.push({
    language,
    root: path.relative(configRoot, root) || ".",
  });
  await atomicWrite(
    configFile,
    JSON.stringify(config, null, 2) + "\n",
    current === null,
  );
  output(
    `Configured ${language}. ${hasBuild ? "Existing build files preserved." : "Created missing project build files."}\n${setup[language]}\nNext: lawspec doctor, then lawspec generate.`,
  );
}
async function main() {
  if (!verb || ["help", "--help", "-h"].includes(verb)) {
    output(
      "LawSpec 0.2.1\nUsage: lawspec init --target <language> [--project <directory>]\n       lawspec check | doctor | explain <unit>::<law> | generate\nOptions: --config <path>, --target <language>, --json\nGeneration: --dry-run, --check\nTargets: " +
        targets.join(", "),
    );
    return;
  }
  if (verb === "--version") {
    output("0.2.1");
    return;
  }
  if (positional.length > (verb === "explain" ? 1 : 0))
    throw new Error(`Unexpected argument: ${positional.join(" ")}`);
  if (verb === "init") return init();
  if (!["check", "doctor", "explain", "generate"].includes(verb))
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
  if (["doctor", "generate"].includes(verb) && !selected.length)
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
  const input = { sources: await sources(config) };
  const compiler = await createCompiler();
  if (verb === "check") {
    const result = diagnostics(await compiler.check(input));
    output(
      options.json
        ? result
        : `Checked ${result.laws.length} executable law(s).`,
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
    if (!indices.length) throw new Error("No matching executable law");
    output(
      options.json
        ? indices.map(({ e, i }) => ({ ...e, expansion: result.expansions[i] }))
        : indices
            .map(
              ({ e, i }) =>
                `${e.owner}::${e.name}\n${e.trace.join("\n=> ")}\n=> ${result.expansions[i]}`,
            )
            .join("\n\n"),
    );
    return;
  }
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
        }),
      ).files,
    );
  const reports = await Promise.all(
    selected.map((t, i) => doctor(t, roots[i])),
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
main().catch((error) => {
  if (options.json)
    output({
      diagnostics: error.diagnostics || [
        { code: "cli", message: error.message, at: null },
      ],
    });
  else console.error(`lawspec: ${error.message}`);
  process.exitCode = 1;
});
