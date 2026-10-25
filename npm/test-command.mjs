// Generated from templates/npm/test-command.mjs by lawspec-dev generate. Do not edit.
// lawspec test: run the generated tests of the laws whose results may have
// changed since their last passing run, through each target's own runner.
//
// A law's result is keyed by everything it depends on: its plan key (the law
// and the Merkle digests of the types and definitions it reaches), the
// compiler build, the target's configuration, the project's build and lock
// files, the toolchain the doctor reports and, for
// a law that calls adapters, every file in the target project that LawSpec
// did not generate. A passing run records each law's key and seed; a law runs
// again when its key changes or with --fresh.
import { createHash, randomUUID } from "node:crypto";
import { readdir, readFile, stat } from "node:fs/promises";
import path from "node:path";
import {presentationChecks,templates} from "./templates.mjs";

// Folders that hold dependencies, build output or caches, not code under test.
const skipped = new Set([".git", ".lawspec", "node_modules", "dist", "build", "target", "out", ".gradle", "bin", "obj", "TestResults",
  ".stack-work", "_build", "deps", ".elixir_ls", "__pycache__", ".hypothesis", ".pytest_cache", ".venv", "venv", ".idea", ".vscode",
  ".scala-build", ".bsp", ".bloop", ".metals", ".build", ".swiftpm"]);
// Build and lock files, which choose the toolchain and dependencies.
const environmentFiles = ["package.json", "package-lock.json", "tsconfig.json", "pyproject.toml", "go.mod",
  "go.sum", "pom.xml", "build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts",
  "Cargo.toml", "Cargo.lock", "stack.yaml", "stack.yaml.lock", "package.yaml",
  "rebar.config", "rebar.config.script", "rebar.lock", "mix.exs", "mix.lock", "gleam.toml", "manifest.toml",
  "global.json", "Directory.Build.props", "Directory.Packages.props", "NuGet.config", "project.scala", "Package.swift", "Package.resolved"];

const digest = (value) => createHash("sha256").update(value).digest("hex");
// The crypto builder owns these outputs. Inputs and other priv/ assets still
// contribute to the adapter digest; rebuilding the NIF cannot invalidate a pass.
const cryptoBuildOutput = (file) => /^priv\/lawspec_crypto_native\.(?:so|dll)(?:\.build|\.\d+\.tmp)?$/.test(file);

// An environment attestation records where a run's dependencies were wired
// and what was observed; it is reporting only, never an input of the
// project, so one written inside the project is not digested. It is known by
// its content, whatever its name or whichever tool wrote it.
// ref:DEC-completed-run-attestation
export function isAttestation(content) {
  try {
    const value = JSON.parse(content);
    return value !== null && typeof value === "object" && value.format === "environment-attestation";
  } catch {
    return false;
  }
}

// Every file in a project that LawSpec did not generate, by content, except
// environment attestations.
export async function projectDigest(root, generated, language) {
  const readable=language?templates(language):{};
  const compact=language?templates(language,{minify:true}):{};
  const hash = createHash("sha256");
  async function walk(folder) {
    const entries = (await readdir(path.join(root, folder), { withFileTypes: true }))
      .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    for (const entry of entries) {
      const relative = folder ? `${folder}/${entry.name}` : entry.name;
      if (entry.isDirectory()) {
        if (!skipped.has(entry.name) && !relative.endsWith("testdata/rapid")) await walk(relative);
      } else if (entry.isFile() && !generated.has(relative) && !cryptoBuildOutput(relative)) {
        const content = await readFile(path.join(root, relative));
        if (relative.endsWith(".json") && isAttestation(content.toString("utf8"))) continue;
        hash.update(relative + "\0").update(content.toString("utf8")===compact[relative]?readable[relative]:content).update("\0");
      }
    }
  }
  await walk("");
  return hash.digest("hex");
}

export async function environmentDigest(root, report, language) {
  // Coverage locations describe build output; native tools can discover more
  // output directories after the first run. Build configuration is hashed below.
  const {coverage: _coverage, ...toolchain} = report ?? {};
  const parts = [JSON.stringify(report ? toolchain : null)];
  const names = (await readdir(root)).filter((name) => environmentFiles.includes(name) || name.endsWith(".cabal")).sort();
  const readable=language?templates(language):{};
  const compact=language?templates(language,{minify:true}):{};
  for (const name of names) {
    const content=await readFile(path.join(root,name),"utf8");
    // Only byte-exact compiler-owned scaffold alternatives are equivalent.
    // A user edit to build configuration always remains an execution input.
    parts.push(name,content===compact[name]?readable[name]:content);
  }
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
      if (entry.isSymbolicLink()) throw new Error(`Recording input is a symbolic link: ${path.join(folder,next)}`);
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

// The result key of each law in a target's test manifest: what the law does
// (the manifest's semantic key), the compiler build, the target, toolchain
// and recorded values, and the adapters a law calls. Never the generated
// file's bytes: a doc edit or a reformat rewrites comments and source links
// but reruns nothing. ref:DEC-content-identity
// A law an environment attestation touches is keyed by how its dependencies
// were wired too, so a run against other endpoints, or the real dependency
// in place of a stand-in, runs it again; other laws' keys are unchanged.
export function lawKeys({ build, target, machineBits, minify, tests, environment, project, recorded = "", attested = new Map() }) {
  const bound = Object.entries(target.nativeBindings??{}).some(([key,value])=>
    key!=="names"&&value!=null&&(Array.isArray(value)?value.length>0:
      typeof value==="object"?Object.keys(value).length>0:value!==""));
  const configuration = entry=>JSON.stringify({ ...target, root: undefined,
    ...(!entry.callsAdapters&&!bound?{nativeBindings:undefined}:{}) });
  return new Map(tests.map((entry) => [entry.law, digest(JSON.stringify([
    build, configuration(entry), machineBits, entry.key,
    environment, entry.callsAdapters||bound ? project : null,
    entry.callsAdapters||bound ? recorded : null,
    ...(attested.has(entry.law) ? [attested.get(entry.law)] : []),
  ]))]));
}

// A law's last result: under its identity, or, when the law was renamed,
// under any earlier identity with the same key.
export function previousResult(previous, law, key) {
  if (previous[law]?.key === key) return previous[law];
  return Object.values(previous ?? {}).find((result) => result?.key === key);
}

const regex = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
const without = (file, extension) => file.slice(0, -extension.length);
const groupBy = (entries, key) => {
  const groups = new Map();
  for (const entry of entries) groups.set(key(entry), [...(groups.get(key(entry)) ?? []), entry]);
  return [...groups.entries()];
};

// Hpack discovers generated modules before native result keys are computed.
// Stack owns this metadata transformation; no compilation or tests run here.
export function configurationInvocations(target) {
  return target.language==='haskell'?[{command:'stack',args:['--no-terminal','config','build-files']}]:[];
}

// Rebar and Mix run their configured compile hooks. Gleam has no corresponding
// hook, so build its generated crypto bridge before starting a native test VM.
export function preparationInvocations(target, files) {
  return target.language === "gleam" && files.some((file) => file.path === "priv/lawspec_crypto_native.c")
    ? [{command: "escript", args: ["lawspec_crypto_build.escript"]}]
    : [];
}

// A changed layout must be accepted by the target compiler/parser before a
// semantic execution result can be reused. No property cases run here.
export function presentationInvocations(target,files,{offline=false}={}) {
  const overrides={python3:target.python,mvn:target.maven,gradle:target.gradle,
    scala:target.scala,swift:target.swift,clojure:target.clojure};
  return (presentationChecks[target.language]??[]).flatMap(check=>{
    const paths=check.suffix?files.filter(file=>file.path.endsWith(check.suffix)).map(file=>file.path):[];
    const extra=offline?({cargo:['--offline'],mvn:['-o'],gradle:['--offline'],dotnet:['--no-restore']}[check.command]??[]):[];
    const args=[...check.args,...extra];
    return (check.each?paths.map(file=>[file]):[paths]).map(paths=>({
      command:overrides[check.command]??check.command,args:[...args,...paths],environment:check.environment}));
  });
}

// Presentation bytes are deliberately kept out of lawKeys. This separate
// digest records which current artifacts have passed native source validation.
export function presentationDigest(files,environment) {
  return digest(JSON.stringify([environment,files.filter(file=>file.ownership==='generated')
    .map(file=>[file.path,file.content])]));
}

// The native invocations that run the harness's benchmarks (lawspec test
// --benchmarks): each target's test command, selecting the tests that
// measure them by the names the manifest gives (entry.name). Benchmarks are
// measured, never asserted; their timings reach the summary through the
// harness statistics.
export function benchmarkInvocations(target, entries, { offline = false } = {}) {
  if (!entries.length) return [];
  const language = target.language;
  if (language === "prolog")
    return [{command: target.python || "python3", args: ["lawspec_test.py",
      ...entries.flatMap(entry => ["--select", `${entry.file}::${entry.name}`])]}];
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
        module: path.posix.basename(entry.file, ".gleam"), function: `${entry.name}_test`
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
    return [{ command: target.maven || "mvn", env: { LAWSPEC_CASE: "" }, args: [...(offline ? ["-o"] : []), "-B", "test",
      `-Dtest=${byClass.map(([name, marks]) => `${name}#${marks.map((e) => e.name).join("+")}`).join(",")}`] }];
  }
  if (language === "kotlin")
    return groupBy(entries, (e) => e.file).map(([file, marks]) => {
      const filter = `(${marks.map((e) => e.name).join("|")})`;
      return { command: target.gradle || "gradle",
        args: [...(offline ? ["--offline"] : []), "--console=plain", "test", "--rerun", "--tests", className(file, "src/test/kotlin", ".kt")],
        env: { "kotest.filter.tests": filter, kotest_filter_tests: filter } };
    });
  // The Clojure runner selects tests by namespace and name prefix.
  if (language === "clojure") {
    const ns = (file) => without(relativeTo(file, "test"), ".clj").replaceAll("/", ".").replaceAll("_", "-");
    return [{ command: target.clojure || "clojure",
      args: ["-M:test", ...entries.flatMap((e) => ["--select", `${ns(e.file)}/${e.name}`])] }];
  }
  // Spock names each feature in words; Gradle's filters select it by name.
  if (language === "groovy")
    return [{ command: target.gradle || "gradle", env: { LAWSPEC_CASE: "" },
      args: [...(offline ? ["--offline"] : []), "--console=plain", "test", "--rerun",
        ...entries.flatMap((e) => ["--tests", `${className(e.file, "src/test/groovy", ".groovy")}.${e.name}`])] }];
  if (language === "rust")
    return groupBy(entries, (e) => e.file).map(([file, marks]) => ({ command: "cargo",
      args: ["test", ...(offline ? ["--offline"] : []), "--test", path.posix.basename(file, ".rs"), "--", "--exact", "--nocapture", ...marks.map((e) => e.name)] }));
  if (language === "fsharp" || language === "csharp")
    return [{ command: "dotnet", args: ["test", ...entries.flatMap((e) => ["--filter-query", `/*/*/*/${e.name}`])] }];
  if (language === "scala")
    return groupBy(entries, (e) => e.file).map(([file, marks]) => ({ command: target.scala || "scala",
      args: ["test", ".", ...(offline ? ["--offline"] : []), "--test-only", className(file, "src/test/scala", ".scala"), "--",
        ...marks.flatMap((e) => ["-z", e.name])] }));
  // Swift Testing selects tests by a regular expression over their ids
  // (Module.Suite/function()), one --filter per benchmark, OR'd.
  if (language === "swift")
    return [{ command: target.swift || "swift", args: ["test", ...entries.flatMap((e) => [
      "--filter", `/${regex(e.name)}\\(`,
      "--filter", `${regex(path.posix.basename(e.file, ".swift"))}/ordered\\(`])],
      env: { LAWSPEC_SWIFT_LAWS: JSON.stringify(entries.map(({unit,name}) => ({unit,name}))),
        LAWSPEC_SWIFT_REPORT: "", LAWSPEC_SWIFT_RUN: "" } }];
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
export function invocations(...arguments_) {
  return nativeInvocations(...arguments_).map(run => {
    const matches=run.matches??run.ran;
    return matches?{...run,matches,ran:test=>test.status==='passed'?matches(test):[]}:run;
  });
}

function nativeInvocations(target, entries, { offline = false, scratch = ".", coverage = null, xdist = false,
  root = process.cwd(), coverageConfig } = {}) {
  if (!entries.length) return [];
  const language = target.language;
  if (language === "prolog") {
    if (coverage) throw new Error("Prolog coverage instrumentation is not integrated");
    const report = path.join(scratch, "prolog.xml");
    const matching = test => entries.filter(entry => entry.kind === "model"
      ? test.name === entry.name : test.name.startsWith(`${entry.name}__`));
    const selections = [...new Set(entries.map(entry => `${entry.file}::${entry.name}`))];
    return [{laws: entries, command: target.python || "python3",
      args: ["lawspec_test.py", ...selections.flatMap(slot => ["--select", slot]), "--junitxml", report],
      report: {kind: "junit", files: [report]}, ran: matching}];
  }
  const testDir = target.testDir;
  const relativeTo = (file, defaultDir) => {
    const directory = testDir || defaultDir;
    return file.startsWith(directory + "/") ? file.slice(directory.length + 1) : file;
  };
  const model = (entry) => entry.kind === "model";
  const named = (entry) => new RegExp(`^${regex(entry.name)}${model(entry) ? "$" : "_"}`);
  const className = (file, defaultDir, extension) => without(relativeTo(file, defaultDir), extension).replaceAll("/", ".");
  if (["erlang", "elixir", "gleam"].includes(language)) {
    const run = randomUUID();
    const file = path.join(scratch, `beam-${run}.jsonl`);
    const identity = (entry) => `${entry.unit}::${entry.name}`;
    const matching = test => entries.filter(entry => test.identity === identity(entry));
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
      matches: matching, ran: test => test.status === "passed" ? matching(test) : [] }];
  }
  if (language === "python")
    return groupBy(entries, (e) => e.file).flatMap(([file, selected], n) => {
      const laws=selected.filter(entry=>!model(entry));
      const models=selected.filter(model);
      const invocations=[];
      const report = path.join(scratch, `pytest-${n}.xml`);
      // parallel: pytest-xdist runs the tests on several workers, when it
      // is installed (lawspec test checks); otherwise one after another.
      const workers = xdist && selected.some((e) => e.parallel) ? ["-p", "xdist", "-n", "auto"] : [];
      const pytest = ["-m", "pytest", "-q", ...workers, file, "-k", laws.map((e) => `${e.name}__`).join(" or "), `--junitxml=${report}`];
      if(laws.length)invocations.push({ laws, command: target.python || "python3",
        args: coverage ? ["-m", "coverage", "run", "--append", `--data-file=${path.join(coverage, ".coverage")}`, ...pytest.slice(1)] : pytest,
        report: { kind: "junit", files: [report] },
        ran: (test) => laws.filter((e) => test.name.startsWith(`${e.name}__`)) });
      if(models.length){
        const modelReport=path.join(scratch,`pytest-model-${n}.xml`);
        const arguments_=["-m","pytest","-q",...workers,
          ...new Set(models.map(entry=>`${file}::${entry.name}`)),`--junitxml=${modelReport}`];
        invocations.push({laws:models,command:target.python||"python3",
          args:coverage?["-m","coverage","run","--append",`--data-file=${path.join(coverage,".coverage")}`,...arguments_.slice(1)]:arguments_,
          report:{kind:"junit",files:[modelReport]},
          ran:test=>models.filter(entry=>test.name===entry.name)});
      }
      return invocations;
    });
  if (language === "javascript" || language === "typescript") {
    const pattern = (e) => model(e)?`^${regex(e.label)}$`:
      `^${regex(e.label)}( example: .*| boundary \\d+| property| known discrepancy| skipped| replay| search)?$`;
    const files = [...new Set(entries.map((e) => language === "typescript"
      ? `dist/${without(e.file, ".ts")}.js` : e.file))];
    const file = path.join(scratch, "node-events.jsonl");
    const runId=randomUUID();
    const matching = test => entries.filter(entry => new RegExp(pattern(entry)).test(test.name));
    // parallel: test files run at the same time too.
    const node = ["--test", ...(entries.some((e) => e.parallel) ? ["--test-concurrency=" + Math.max(2, (globalThis.navigator?.hardwareConcurrency ?? 2))] : []),
      `--test-name-pattern=(${entries.map(pattern).join("|")})`,
      "--test-reporter=spec", "--test-reporter-destination=stdout",
      `--test-reporter=${new URL('./node-events-reporter.mjs',import.meta.url).href}`,
      `--test-reporter-destination=${file}`, ...files];
    const run = { laws: entries, command: coverage ? "npx" : process.execPath,
      args: coverage ? ["--no-install", "c8", "--reporter=text", `--reports-dir=${coverage}`, process.execPath, ...node] : node,
      // A CLI launched from node:test must start an independent native run.
      env:{LAWSPEC_NODE_RUN:runId,NODE_TEST_CONTEXT:undefined},report: { kind: "node-events", file, run:runId },
      matches: matching, ran: test => test.status === 'passed' ? matching(test) : [] };
    return language === "typescript"
      ? [{ laws: [], command: "npm", args: ["exec", "--", "tsc", "-p", "tsconfig.json"] }, run]
      : [run];
  }
  if (language === "go")
    return groupBy(entries, (e) => path.posix.dirname(e.file)).map(([directory, laws]) => ({
      laws, command: "go",
      args: ["test", "-json", "-count=1", ...(coverage ? ["-cover", `-coverprofile=${path.join(coverage, `go-${directory.replaceAll("/", "_") || "root"}.out`)}`] : []),
        `./${directory}`, "-run", laws.some(model)?
          `^(${[...new Set(laws.map(e=>regex(e.name)+(model(e)?"$":"_")))].join("|")})`:
          `^(${laws.map((e) => regex(e.name)).join("|")})_`],
      report: { kind: "go-json" },
      ran: (test) => laws.filter((e) => named(e).test(test.name) && test.name !== `${e.name}_Boundaries`) }));
  if (language === "java") {
    const byClass = groupBy(entries, (e) => className(e.file, "src/test/java", ".java"));
    return [{ laws: entries, command: target.maven || "mvn", env: { LAWSPEC_CASE: "" },
      args: [...(offline ? ["-o"] : []), "-B", ...(coverage ? ["org.jacoco:jacoco-maven-plugin:prepare-agent"] : []), "test",
        ...(coverage ? ["org.jacoco:jacoco-maven-plugin:report"] : []),
        `-Dtest=${byClass.map(([name, laws]) => `${name}#${[...new Set(laws.map((e) => model(e)?e.name:`${e.name}_*`))].join("+")}`).join(",")}`],
      report: { kind: "junit", directory: "target/surefire-reports" },
      ran: (test) => entries.filter((e) => test.classname === (e.scope??className(e.file, "src/test/java", ".java")) && named(e).test(test.name)) }];
  }
  // Kotest names tests by string, which Gradle's method filters cannot
  // select. Kotest's own filter selects them within each class: one pattern,
  // matched against whole names, whose * becomes .*? (several comma-separated
  // patterns must all match, so alternatives go in one group).
  if (language === "kotlin")
    return groupBy(entries, (e) => e.file).map(([file, laws]) => {
      const filter = laws.some(model)?
        `(${[...new Set(laws.map(e=>regex(e.name)+(model(e)?"":"_.*")))].join("|")})`:
        `(${laws.map((e) => `${e.name}_`).join("|")})*`;
      const name = className(file, "src/test/kotlin", ".kt");
      return { laws, command: target.gradle || "gradle",
        args: [...(offline ? ["--offline"] : []), "--console=plain", "test", ...(coverage ? ["koverXmlReport"] : []), "--rerun", "--tests", name],
        env: { "kotest.filter.tests": filter, kotest_filter_tests: filter },
        report: { kind: "junit", directory: "build/test-results/test" },
        ran: (test) => laws.filter((e) => test.classname === (e.scope??name) && named(e).test(test.name)) };
    });
  // ScalaTest selects tests by substring (-z): each law's tests are named
  // after it, then a kind after a separator no name contains. Its JUnit
  // reporter writes one file per suite (-u).
  if (language === "scala")
    return groupBy(entries, (e) => e.file).map(([file, laws], n) => {
      const name = className(file, "src/test/scala", ".scala");
      const directory = path.join(scratch, `scalatest-${n}`);
      // --coverage: Scala 3 instruments the code (scoverage's format).
      // The tests themselves are not measured.
      const testRoot = target.testDir || "src/test/scala";
      const measured = coverage ? ["-O", `-coverage-out:${path.resolve(coverage, "data")}`,
        "-O", `-coverage-exclude-files:.*/${testRoot.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}/.*`] : [];
      return { laws, command: target.scala || "scala",
        args: ["test", ".", ...(offline ? ["--power","--offline"] : []), ...measured, "--test-only", name, "--",
          ...[...new Map(laws.map(e=>[(model(e)?"exact:":"prefix:")+e.name,e])).values()]
            .flatMap(e=>[model(e)?"-t":"-z",model(e)?e.name:`${e.name}_`]), "-u", directory],
        report: { kind: "junit", directory: path.relative(root, directory) || "." },
        ran: (test) => laws.filter((e) => test.classname === (e.scope??name) && named(e).test(test.name)) };
    });
  // A Clojure test is the law's words, a double dash and the kind of test
  // (LawSpec.TestNames); the runner selects tests by namespace and prefix.
  if (language === "clojure") {
    const ns = (e) => e.scope??without(relativeTo(e.file, "test"), ".clj").replaceAll("/", ".").replaceAll("_", "-");
    return [{ laws: entries, command: target.clojure || "clojure",
      args: ["-M:test", ...[...new Map(entries.map(e=>[(model(e)?"exact:":"prefix:")+ns(e)+"/"+e.name,e])).values()]
        .flatMap(e=>[model(e)?"--select-exact":"--select",`${ns(e)}/${e.name}${model(e)?"":"--"}`])],
      report: { kind: "junit", directory: "target/test-results" },
      ran: (test) => entries.filter((e) => test.classname === ns(e) &&
        (model(e)?test.name===e.name:test.name.startsWith(`${e.name}--`))) }];
  }
  // A Spock feature is the law's words, a colon and the kind of test
  // (LawSpec.TestNames), so "name: *" selects one law's features only.
  if (language === "groovy") {
    const name = (e) => className(e.file, "src/test/groovy", ".groovy");
    return [{ laws: entries, command: target.gradle || "gradle", env: { LAWSPEC_CASE: "" },
      args: [...(offline ? ["--offline"] : []), "--console=plain", "test", ...(coverage ? ["jacocoTestReport"] : []), "--rerun",
        ...[...new Set(entries.map(e=>`${e.scope??name(e)}.${e.name}${model(e)?"":": *"}`))].flatMap(name=>["--tests",name])],
      report: { kind: "junit", directory: "build/test-results/test" },
      ran: (test) => entries.filter((e) => test.classname === (e.scope??name(e)) &&
        (model(e)?test.name===e.name:test.name.startsWith(`${e.name}: `))) }];
  }
  // A law's tests are a module of its name (LawSpec.TestNames), selected
  // by the module's path; a model's test is selected by its exact name.
  if (language === "rust")
    return groupBy(entries, (e) => e.file).flatMap(([file, entries]) =>
      [entries.filter((e) => !model(e)), entries.filter(model)].filter((laws) => laws.length).map((laws) => ({
        laws, command: "cargo",
        args: [...(coverage ? ["llvm-cov", "--no-report"] : []), "test", ...(offline ? ["--offline"] : []), "--test", path.posix.basename(file, ".rs"), "--",
          ...(model(laws[0]) ? ["--exact", ...new Set(laws.map((e) => e.name))] : [...new Set(laws.map((e) => `${e.name}::`))])],
        report: { kind: "lines", pattern: /^test (\S+) \.\.\. (ok|FAILED|ignored)/ },
        ran: (test) => laws.filter((e) => model(e) ? test.name === e.name : test.name.startsWith(`${e.name}::`)) })));
  // xUnit v3 on Microsoft.Testing.Platform selects test methods with its
  // query filter (assembly/namespace/class/method, one per law, OR'd), and
  // reports each test by its display name: the law's label, then its kind.
  if (language === "fsharp" || language === "csharp") {
    const report = "lawspec-junit.xml";
    const results = path.resolve(scratch, "dotnet-results");
    const kinds = "example \\d+: .*|boundary(?: \\d+(?: — .*)?(?:\\(caseIndex: \\d+\\))?)?|statistics|property|search|replay|skipped|known discrepancy";
    const pattern = (e) => new RegExp(`^${regex(e.label)}( (${kinds}))?$`);
    const measured = coverage ? path.resolve(coverage, "dotnet.cobertura.xml") : null;
    return [{ laws: entries, command: "dotnet",
      args: ["test", ...entries.flatMap((e) => ["--filter-query", `/*/*/*/${e.name}_*`, "--filter-query", `/*/*/*/${e.name}`]),
        "--report-xunit-junit", "--report-xunit-junit-filename", report, "--results-directory", results,
        ...(measured ? ["--coverage", "--coverage-output-format", "cobertura", "--coverage-output", measured] : [])],
      report: { kind: "junit", files: [path.join(results, report)] },
      ran: (test) => entries.filter((e) => pattern(e).test(test.name)) }];
  }
  // Ordered Swift groups expose their parameterized aggregate in JUnit;
  // the native lifecycle report identifies each completed invocation inside it.
  if (language === "swift") {
    const results = path.resolve(scratch);
    const suite = (e) => path.posix.basename(e.file, ".swift");
    const ordered = entries.filter((e) => e.scope === "ordered");
    const token = randomUUID();
    const output = ordered.length ? `swift-lawspec-${token}` : "swift-lawspec";
    const files = [path.join(results, `${output}-swift-testing.xml`)];
    const events = path.join(results, `${output}.jsonl`);
    const test = (e) => e.scope === "ordered" ? `${regex(suite(e))}/ordered\\(` :
      `${regex(suite(e))}/${regex(e.name)}(_[A-Za-z0-9]+)?\\(`;
    return [{ laws: entries, command: target.swift || "swift",
      args: ["test", ...(coverage ? ["--enable-code-coverage"] : []),
        ...[...new Set(entries.map(test))].flatMap((selector) => ["--filter", selector]),
        "--xunit-output", path.join(results, `${output}.xml`)],
      env: { LAWSPEC_SWIFT_LAWS: JSON.stringify(ordered.map(({unit,name}) => ({unit,name}))),
        LAWSPEC_SWIFT_REPORT: ordered.length ? events : "", LAWSPEC_SWIFT_RUN: ordered.length ? token : "" },
      report: ordered.length ? { kind: "swift-events", files, file: events, run: token,
        groups: ordered.map((e) => ({unit:e.unit,law:e.name,suite:suite(e),
          minimum:typeof e.knownDiscrepancy === "string" ? 1 : Math.max(1,e.coverage?.cases ?? 1)})) } :
        { kind: "junit", files },
      ran: (result) => entries.filter((e) => e.scope === "ordered" ?
        result.unit === e.unit && result.nativeName === e.name :
        result.classname?.split(".").pop() === suite(e) &&
        new RegExp(`^${regex(e.name)}(_[A-Za-z0-9]+)?(\\(|$)`).test(result.name)) }];
  }
  if (language === "haskell") {
    const module = (e) => without(relativeTo(e.file, "test"), "Spec.hs").replaceAll("/", ".");
    const matches = [...new Set(entries.map((e) => model(e)?
      `/${e.scope??module(e)}/${e.unit} models/${e.name}/`:`${module(e)}/${e.name}_`))];
    return [{ laws: entries, command: "stack",
      args: ["--no-terminal", "test", ...(coverage ? ["--coverage"] : []), "--test-arguments",
        matches.map((m) => `--match ${m.includes(" ")?JSON.stringify(m):m}`).join(" ")],
      report: { kind: "hspec" },
      ran: (test) => entries.filter((e) => test.classname === (e.scope??module(e)) && named(e).test(test.name)) }];
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
  clojure: { tool: "cloverage", install: "add cloverage to a :coverage alias in deps.edn" },
  groovy: { tool: "JaCoCo", install: "add id 'jacoco' to the plugins of build.gradle" },
  rust: { tool: "cargo-llvm-cov", install: "cargo install cargo-llvm-cov" },
  haskell: { tool: "hpc", install: "(built into GHC; stack test --coverage)" },
  fsharp: { tool: "Microsoft code coverage", install: "add the Microsoft.Testing.Extensions.CodeCoverage package to the test project" },
  csharp: { tool: "Microsoft code coverage", install: "add the Microsoft.Testing.Extensions.CodeCoverage package to the test project" },
  scala: { tool: "scoverage", install: "(built into Scala 3; Scala CLI fetches the scoverage reporter)" },
  swift: { tool: "llvm-cov", install: "(built into the Swift toolchain; swift test --enable-code-coverage)" },
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
    !previousResult(previous, entry.law, keys.get(entry.law)));
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
// counts, flaky and known-discrepancy outcomes, benchmarks.
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
  if (report?.kind === "swift-events") return swiftExecutedTests(report, output, root, since);
  if(report?.kind==='node-events') {
    const raw=await readFile(path.resolve(root,report.file),'utf8').catch(()=>'');
    let rows;
    try {rows=raw.trim().split('\n').map(line=>JSON.parse(line));}catch{return [];}
    if(rows.length<2||rows[0]?.event!=='start'||rows.at(-1)?.event!=='end'||
      rows.some(row=>row?.version!==1||row?.run!==report.run)||
      rows.at(-1).count!==rows.length-2) return [];
    const tests=rows.slice(1,-1);
    if(tests.some(row=>row?.event!=='test'||typeof row.name!=='string'||typeof row.classname!=='string'||
      !['passed','failed','skipped'].includes(row.status)||
      (row.time!==undefined&&(!Number.isFinite(row.time)||row.time<0))||
      (row.failure!==undefined&&typeof row.failure!=='string')))return [];
    return tests;
  }
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
      const location=path.resolve(root,file);
      const info=await stat(location).catch(()=>null);
      if(!info||info.mtimeMs<since)continue;
      const xml=await readFile(location,"utf8").catch(()=>"");
      const attributes=opening=>Object.fromEntries([...opening.matchAll(/\s([A-Za-z_:][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)')/g)]
        .map(match=>[match[1],unescapeXml(match[2]??match[3])]));
      for(const element of junitElements(xml,["testcase"])){
        const values=attributes(element.opening);
        const native=junitElements(element.xml,["failure","error","skipped"]);
        const failure=native.filter(element=>element.name!=="skipped");
        const incomplete=junitElements(element.xml,["property"]).some(property=>{
          const value=attributes(property.opening);
          return value.name==='lawspec.status'&&value.value==='incomplete';
        });
        const status=incomplete?"incomplete":failure.length?"failed":native.length?"skipped":"passed";
        const detail=element=>[attributes(element.opening).message,
          unescapeXml(element.xml.slice(element.opening.length).replace(/<\/(failure|error|skipped)>\s*$/,"")
            .replace(/<!\[CDATA\[([\s\S]*?)\]\]>/g,(_,text)=>text))].filter(Boolean).join("\n");
        const time=values.time===undefined?undefined:Number(values.time);
        tests.push({name:(values.name??"").replace(/\(\)$/, ""),classname:values.classname??"",status,
          ...(Number.isFinite(time)&&time>=0?{time}:{}),
          ...(failure.length?{failure:failure.map(detail).join("\n")}:
            status==="skipped"?{reason:native.map(detail).join("\n")}: {})});
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
      const example = line.match(/^\s+(law\S*?):?(?:\s.*)?\s\[([✔✘])\]\s*$/) ??
        line.match(/^\s+(model .+?|supervision)\s\[([✔✘])\]\s*$/);
      if (example) tests.push({ name: example[1], classname: module, status: example[2] === "✔" ? "passed" : "failed" });
    }
    return tests;
  }
  return [];
}

// Swift's XML seals the native aggregate; runtime events refine that completed
// aggregate into individually attributable cases. Neither channel suffices alone.
async function swiftExecutedTests(report, output, root, since) {
  const native = await executedTests({kind:"junit",files:report.files}, output, root, since);
  const ordinary = native.filter((test) => test.name !== "ordered(_:)");
  const raw = await readFile(path.resolve(root,report.file), "utf8").catch(() => "");
  let rows;
  try { rows = raw.trim().split("\n").map((line) => JSON.parse(line)); } catch { return ordinary; }
  if (!rows.length || rows.some((row) => !row || row.version !== 1 || row.run !== report.run)) return ordinary;
  const key = (unit,name) => JSON.stringify([unit,name]);
  const expected = new Map(report.groups.map((group) => [key(group.unit,group.law),group]));
  const plans = new Map(), cases = new Map(), starts = new Set(), ends = new Map();
  for (const row of rows) {
    if (typeof row.unit !== "string") return ordinary;
    if (row.event === "plan") {
      if (!Array.isArray(row.cases) || !row.cases.length) return ordinary;
      const previous = plans.get(row.unit);
      if (previous !== undefined) {
        if (JSON.stringify(previous) !== JSON.stringify(row.cases)) return ordinary;
        continue;
      }
      plans.set(row.unit,row.cases);
      for (const item of row.cases) {
        if (!item || typeof item.id !== "string" || !item.id || typeof item.name !== "string" || !item.name ||
          typeof item.law !== "string" || !expected.has(key(row.unit,item.law))) return ordinary;
        const id = key(row.unit,item.id);
        if (cases.has(id)) return ordinary;
        cases.set(id,{...item,unit:row.unit});
      }
    } else if (row.event === "case-start" || row.event === "case-end") {
      const id = key(row.unit,row.id), item = cases.get(id);
      if (!item || item.name !== row.name || item.law !== row.law) return ordinary;
      if (row.event === "case-start") {
        if (starts.has(id)) return ordinary;
        starts.add(id);
      } else {
        if (!starts.has(id) || ends.has(id) || !["passed","failed"].includes(row.status) ||
          !Number.isFinite(row.time) || row.time < 0 ||
          (row.failure !== undefined && typeof row.failure !== "string")) return ordinary;
        ends.set(id,row);
      }
    } else return ordinary;
  }
  if (cases.size !== starts.size || cases.size !== ends.size) return ordinary;
  const completed = [];
  for (const group of expected.values()) {
    const members = [...cases.values()].filter((item) => item.unit === group.unit && item.law === group.law);
    if (members.length < group.minimum) return ordinary;
    const aggregates = native.filter((test) => test.name === "ordered(_:)" &&
      test.classname.split(".").pop() === group.suite);
    if (aggregates.length !== 1 || !["passed","failed"].includes(aggregates[0].status)) return ordinary;
    const aggregate = aggregates[0];
    // A framework failure outside the invocation body cannot credit that body's
    // earlier successes. Preserve them as incomplete observations instead.
    const suiteFailed = [...cases.values()].some((item) => {
      const expectedGroup = expected.get(key(item.unit,item.law));
      return expectedGroup.suite === group.suite && ends.get(key(item.unit,item.id)).status === "failed";
    });
    if (aggregate.status === "passed" && suiteFailed) return ordinary;
    for (const item of members) {
      const result = ends.get(key(item.unit,item.id));
      const incomplete = aggregate.status === "failed" && !suiteFailed;
      completed.push({name:item.id,classname:aggregate.classname,identity:`${item.unit}::${item.law}`,
        unit:item.unit,nativeName:item.law,
        status:incomplete ? "incomplete" : result.status,time:result.time,
        ...(incomplete ? {failure:aggregate.failure ?? "Swift aggregate failed outside its invocation bodies"} :
          result.failure === undefined ? {} : {failure:result.failure})});
    }
  }
  return [...ordinary,...completed];
}

// JUnit XML for a runner that writes none, from the tests it printed.
export function junitFromTests(tests) {
  const failures = tests.filter((t) => t.status === "failed").length;
  const errors = tests.filter((t) => t.status === "incomplete").length;
  const skipped = tests.filter((t) => t.status === "skipped").length;
  // A BEAM scheduler wraps native functions from several units. Its module
  // is not the declaring class: retain the unit from the validated identity.
  const classname = (test) => {
    const separator = typeof test.identity === "string" ? test.identity.lastIndexOf("::") : -1;
    return separator > 0 ? test.identity.slice(0, separator) : test.classname ?? "";
  };
  return `<testsuite name="lawspec" tests="${tests.length}" failures="${failures}"${errors ? ` errors="${errors}"` : ""}${skipped ? ` skipped="${skipped}"` : ""}>\n` +
    tests.map((t) => `  <testcase classname="${escapeXml(classname(t))}" name="${escapeXml(t.name)}"` +
      (Number.isFinite(t.time) ? ` time="${t.time}"` : "") +
      (t.status === "failed" ? `><failure message="${escapeXml(t.failure ?? "failed")}"/></testcase>` :
        t.status === "incomplete" ? `><properties><property name="lawspec.status" value="incomplete"/></properties><error message="${escapeXml(t.failure ?? t.reason ?? "incomplete execution")}"/></testcase>` :
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
