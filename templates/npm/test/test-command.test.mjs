import { test } from "node:test";
import assert from "node:assert/strict";
import { benchmarkInvocations, preparationInvocations, invocations, lawKeys, recordedDigest, selectByTags, mergeJunit, junitFromTests,
  environmentDigest, projectDigest, testsToRun } from "../test-command.mjs";

// A manifest entry, named as each target names a law's tests (LawSpec.TestNames).
const names = { python: (i) => `test_law_${i}`, go: (i) => `TestLaw${i}`, rust: (i) => `law_law_${i}` };
const law = (index, file, label = `example.unit::law ${index}`, language = "python") =>
  ({ law: `example.unit::law::law ${index}`, unit: "example.unit", label, index, file, key: `k${index}`, callsAdapters: true,
    name: (names[language] ?? ((i) => `lawLaw${i}`))(index), tags: [] });

test("recorded failures replay even after restoring a previously passing adapter", () => {
  const entries = [law(1, "test/a"), law(2, "test/a")];
  const keys = new Map(entries.map((entry) => [entry.law, entry.key]));
  const previous = Object.fromEntries(entries.map((entry) => [entry.law, {key: entry.key}]));
  assert.deepEqual(testsToRun(entries, keys, previous, {}), []);
  assert.deepEqual(testsToRun(entries, keys, previous, {[entries[0].law]: {seed: 911}}), [entries[0]]);
  assert.deepEqual(testsToRun(entries, keys, {}, {}), entries);
  for (const flag of ["fresh", "coverage", "updateRecorded"])
    assert.deepEqual(testsToRun(entries, keys, previous, {}, {[flag]: true}), entries);
});

test("prepares the Gleam crypto bridge through its generated builder", () => {
  const files = [{path: "priv/lawspec_crypto_native.c"}];
  assert.deepEqual(preparationInvocations({language: "gleam"}, files),
    [{command: "escript", args: ["lawspec_crypto_build.escript"]}]);
  assert.deepEqual(preparationInvocations({language: "gleam"}, []), []);
  for (const language of ["erlang", "elixir", "javascript"])
    assert.deepEqual(preparationInvocations({language}, files), []);
});

test("native crypto build outputs do not invalidate cached adapter results", async t => {
  const {mkdtemp, mkdir, writeFile, rm} = await import("node:fs/promises");
  const {default: os} = await import("node:os");
  const {default: path} = await import("node:path");
  const root = await mkdtemp(path.join(os.tmpdir(), "lawspec-crypto-digest-"));
  t.after(() => rm(root, {recursive: true, force: true}));
  await mkdir(path.join(root, "priv"));
  await writeFile(path.join(root, "priv/lawspec_crypto_native.c"), "source");
  await writeFile(path.join(root, "priv/identity.seed"), "key bytes");
  const generated = new Set(["priv/lawspec_crypto_native.c"]);
  const original = await projectDigest(root, generated);
  for (const file of ["lawspec_crypto_native.so", "lawspec_crypto_native.so.build", "lawspec_crypto_native.so.1234.tmp", "lawspec_crypto_native.dll"])
    await writeFile(path.join(root, "priv", file), "compiled output");
  assert.equal(await projectDigest(root, generated), original);
  await writeFile(path.join(root, "priv/identity.seed"), "changed key");
  assert.notEqual(await projectDigest(root, generated), original);
  assert.notEqual(await projectDigest(root, new Set()), await projectDigest(root, generated));
});

test("coverage output discovery cannot invalidate the toolchain cache", async t => {
  const {mkdtemp, writeFile, rm} = await import("node:fs/promises");
  const {default: os} = await import("node:os");
  const {default: path} = await import("node:path");
  const root = await mkdtemp(path.join(os.tmpdir(), "lawspec-coverage-digest-"));
  t.after(() => rm(root, {recursive: true, force: true}));
  const report = {target: "erlang", ok: true, versions: {otp: "29.1.1"}};
  const before = await environmentDigest(root, report);
  assert.equal(await environmentDigest(root, {...report, coverage: {beamDirectories: ["new/ebin"]}}), before);
  assert.notEqual(await environmentDigest(root, {...report, versions: {otp: "29.1.2"}}), before);
  await writeFile(path.join(root, "rebar.config"), "{erl_opts, [debug_info]}.\n");
  assert.notEqual(await environmentDigest(root, report), before);
});

test("selects whole test names, so law 1 never selects law 10", () => {
  const python = invocations({ language: "python" }, [law(1, "tests/test_example_unit_lawspec.py")]);
  assert.deepEqual(python[0].args.slice(-3, -1), ["-k", "test_law_1__"]);
  const go = invocations({ language: "go" }, [law(1, "example/unit/lawspec_test.go", undefined, "go"), law(10, "example/unit/lawspec_test.go", undefined, "go")]);
  assert.equal(go.length, 1);
  assert.match("TestLaw10_Property", new RegExp(go[0].args.at(-1)));
  assert.doesNotMatch("TestLaw10_Property", new RegExp(go[0].args.at(-1).replace("TestLaw1|TestLaw10", "TestLaw1")));
  const rust = invocations({ language: "rust" }, [law(1, "tests/example_unit_lawspec.rs", undefined, "rust")]);
  assert.deepEqual(rust[0].args, ["test", "--test", "example_unit_lawspec", "--", "--exact", "law_law_1"]);
  const kotlin = invocations({ language: "kotlin" }, [law(1, "src/test/kotlin/example/UnitLawSpecTest.kt", undefined, "kotlin")]);
  const pattern = new RegExp(`^${kotlin[0].env["kotest.filter.tests"].replace("*", ".*?")}$`);
  assert.ok(pattern.test("lawLaw1_property: example.unit::law 1"));
  assert.ok(!pattern.test("lawLaw10_example0"));
  assert.deepEqual(kotlin[0].args.slice(-2), ["--tests", "example.UnitLawSpecTest"]);
});

test("selects laws by their harness tags", () => {
  const entries = [{ ...law(0, "t"), tags: ["network"] }, { ...law(1, "t"), tags: ["fast"] }, law(2, "t")];
  assert.deepEqual(selectByTags(entries, ["network"]).map((e) => e.index), [0]);
  assert.deepEqual(selectByTags(entries, [], ["network"]).map((e) => e.index), [1, 2]);
  assert.deepEqual(selectByTags(entries, ["network", "fast"], ["fast"]).map((e) => e.index), [0]);
});

test("merges JUnit reports across targets", () => {
  const merged = mergeJunit([
    { target: "python", xml: '<testsuites><testsuite name="pytest" tests="2" failures="1"><testcase name="a"/></testsuite></testsuites>' },
    { target: "go", xml: junitFromTests([{ name: "TestA_Property", classname: "p", status: "passed" }]) }]);
  assert.match(merged, /<testsuites tests="3" failures="1"/);
  assert.match(merged, /name="python: pytest"/);
  assert.match(merged, /name="go: lawspec"/);
  assert.match(merged, /<testcase classname="p" name="TestA_Property"\/>/);
});

test("JUnit preserves skipped obligations without counting them as failures", () => {
  const xml = junitFromTests([
    {name: "passed", classname: "example", status: "passed", time: 0.01},
    {name: "failed", classname: "example", status: "failed", failure: "bad <value>"},
    {name: '雪 "pending"', classname: "example.skips", status: "skipped", reason: 'needs <adapter> & "setup"'},
  ]);
  assert.match(xml, /tests="3" failures="1" skipped="1"/);
  assert.match(xml, /<skipped message="needs &lt;adapter&gt; &amp; &quot;setup&quot;"\/>/);
  assert.match(xml, /name="雪 &quot;pending&quot;"/);
  assert.equal((xml.match(/<failure\b/g) ?? []).length, 1);
  assert.equal((xml.match(/<skipped\b/g) ?? []).length, 1);
});

test("JUnit keeps scheduled BEAM tests from different units distinct", () => {
  const xml = junitFromTests([
    {name: "law_check__case_0", classname: "lawspec_beam_schedule", identity: "example.first::law_check", status: "passed"},
    {name: "law_check__case_0", classname: "lawspec_beam_schedule", identity: "example.second::law_check", status: "passed"},
    {name: "ordinary", classname: "native_application_tests", identity: "", status: "passed"},
  ]);
  assert.match(xml, /classname="example.first" name="law_check__case_0"/);
  assert.match(xml, /classname="example.second" name="law_check__case_0"/);
  assert.match(xml, /classname="native_application_tests" name="ordinary"/);
  assert.doesNotMatch(xml, /classname="lawspec_beam_schedule"/);
});

test("keeps Node's top-level JUnit cases, statuses and project identities", () => {
  const xml = '<testsuites><testcase name="pass" time="0.1"/>' +
    '<testcase name="fail"><failure message="wrong value">native stack</failure></testcase>' +
    '<testcase name="error"><error message="setup"/></testcase>' +
    '<testcase name="skip"><skipped/></testcase></testsuites>';
  const merged = mergeJunit([
    {target: 'javascript (first & project)', xml},
    {target: 'javascript (second project)', xml: '<testsuite name="grouped" tests="1"><testcase name="other"/></testsuite>'},
  ]);
  assert.match(merged, /<testsuites tests="5" failures="1" errors="1" skipped="1">/);
  assert.match(merged, /name="javascript \(first &amp; project\): native"/);
  assert.match(merged, /name="javascript \(second project\): grouped"/);
  assert.match(merged, /<testcase name="pass" time="0\.1"\/>/);
  assert.match(merged, /<failure message="wrong value">native stack<\/failure>/);
  assert.equal([...merged.matchAll(/<testcase\b/g)].length, 5);
});

test("keeps nested and empty JUnit suites without counting their cases twice", () => {
  const xml = `<testsuites><testsuite name="empty" tests="0"/>
<testsuite name='parent &amp; "group"'><testsuite name="child" tests="1">
<testcase name="nested"><failure><![CDATA[<testcase name="fake"/><error/>]]></failure></testcase>
</testsuite><testcase name="sibling"/></testsuite>
<!-- <testsuite name="fake"><testcase name="fake"/></testsuite> -->
<testcase name="loose"><system-out><![CDATA[<failure/>]]></system-out></testcase></testsuites>`;
  const merged = mergeJunit([{target: "javascript", xml}]);
  assert.match(merged, /<testsuites tests="3" failures="1" errors="0" skipped="0">/);
  assert.match(merged, /<testsuite name="javascript: empty" tests="0"\/>/);
  assert.match(merged, /<testsuite name="javascript: parent &amp; &quot;group&quot;"><testsuite name="child" tests="1">/);
  assert.match(merged, /<\/testsuite><testcase name="sibling"\/><\/testsuite>/);
  assert.match(merged, /<testsuite name="javascript: native" tests="1" failures="0" errors="0" skipped="0">/);
  assert.match(merged, /<!\[CDATA\[<testcase name="fake"\/><error\/>\]\]>/);
  assert.doesNotMatch(merged, /name="javascript: fake"/);
});

test("asks each runner to measure coverage", () => {
  const python = invocations({ language: "python" }, [law(0, "tests/t.py")], { coverage: ".lawspec/coverage/python" });
  assert.deepEqual(python[0].args.slice(0, 4), ["-m", "coverage", "run", "--append"]);
  const go = invocations({ language: "go" }, [law(0, "a/lawspec_test.go", undefined, "go")], { coverage: "c" });
  assert.ok(go[0].args.includes("-cover"));
  const haskell = invocations({ language: "haskell" }, [law(0, "test/A/BSpec.hs", undefined, "haskell")], { coverage: "c" });
  assert.ok(haskell[0].args.includes("--coverage"));
});

test("runs each unit's laws separately where names repeat across units", () => {
  const entries = [law(0, "tests/test_a_lawspec.py"), law(0, "tests/test_b_lawspec.py")];
  assert.equal(invocations({ language: "python" }, entries).length, 2);
  const java = invocations({ language: "java" }, [law(0, "src/test/java/a/ALawSpecTest.java", undefined, "java"), law(2, "src/test/java/b/BLawSpecTest.java", undefined, "java")]);
  assert.equal(java.length, 1);
  assert.equal(java[0].args.at(-1), "-Dtest=a.ALawSpecTest#lawLaw0_*,b.BLawSpecTest#lawLaw2_*");
});

test("selects JavaScript and TypeScript tests by their law's label", () => {
  const entries = [law(0, "test/example_unit.lawspec.test.ts", "example.unit::a (special) law")];
  const [compile, run] = invocations({ language: "typescript" }, entries);
  assert.deepEqual(compile.args, ["exec", "--", "tsc", "-p", "tsconfig.json"]);
  assert.equal(run.args.at(-1), "dist/test/example_unit.lawspec.test.js");
  const pattern = new RegExp(run.args[1].slice("--test-name-pattern=".length));
  assert.ok(pattern.test("example.unit::a (special) law property"));
  assert.ok(pattern.test("example.unit::a (special) law example: zero"));
  assert.ok(!pattern.test("example.unit::a (special) law and more"));
});

test("follows custom test directories and Haskell's spec paths", () => {
  const java = invocations({ language: "java", testDir: "checks" }, [law(0, "checks/a/ALawSpecTest.java")]);
  assert.match(java[0].args.at(-1), /^-Dtest=a\.ALawSpecTest#/);
  const haskell = invocations({ language: "haskell" }, [law(3, "test/Example/UnitSpec.hs", undefined, "haskell")]);
  assert.match(haskell[0].args.at(-1), /--match Example\.Unit\/lawLaw3_/);
});

test("a law's key changes with its adapters only when it calls them", () => {
  const files = [{ path: "t", content: "x" }];
  const tests = [law(0, "t"), { ...law(1, "t"), callsAdapters: false }];
  const keys = (project) => lawKeys({ build: "b", target: { language: "python" }, machineBits: 64, minify: false,
    tests, files, environment: "e", project });
  const before = keys("one"), after = keys("two");
  assert.notEqual(before.get(tests[0].law), after.get(tests[0].law));
  assert.equal(before.get(tests[1].law), after.get(tests[1].law));
});

import { mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { executedTests } from "../test-command.mjs";

// What each runner reports, reduced to the laws whose tests actually ran.
async function ranLaws(target, entries, report, output = "") {
  const scratch = await mkdtemp(path.join(os.tmpdir(), "lawspec-report-"));
  try {
    const [run] = invocations(target, entries, { scratch }).filter((r) => r.laws.length);
    if (report !== undefined) {
      const file = run.report.files?.[0] ?? path.join(scratch, run.report.directory ?? "", "TEST-report.xml");
      await import("node:fs/promises").then((fs) => fs.mkdir(path.dirname(file), { recursive: true }));
      await writeFile(file, report);
    }
    const tests = await executedTests(run.report, output, scratch, 0);
    return [...new Set(tests.flatMap(run.ran))].map((e) => e.index).sort();
  } finally {
    await rm(scratch, { recursive: true, force: true });
  }
}

test("counts only the tests a runner reports as run", async () => {
  const python = [law(0, "tests/t.py"), law(1, "tests/t.py")];
  assert.deepEqual(await ranLaws({ language: "python" }, python,
    '<testsuite><testcase classname="tests.t" name="test_law_0__property"/>' +
    '<testcase classname="tests.t" name="test_law_1__example0"><skipped/></testcase></testsuite>'), [0]);
  // Kotest skips what its filter excludes; a filter matching nothing skips all.
  const kotlin = [law(0, "src/test/kotlin/example/UnitLawSpecTest.kt", undefined, "kotlin")];
  assert.deepEqual(await ranLaws({ language: "kotlin" }, kotlin,
    '<testsuite><testcase name="lawLaw0_property: example.unit::law 0" classname="example.UnitLawSpecTest"><skipped/></testcase></testsuite>'), []);
  assert.deepEqual(await ranLaws({ language: "kotlin" }, kotlin,
    '<testsuite><testcase name="lawLaw0_property: example.unit::law 0" classname="example.UnitLawSpecTest" time="0.1"></testcase></testsuite>'), [0]);
  const java = [law(2, "src/test/java/example/UnitLawSpecTest.java", undefined, "java")];
  assert.deepEqual(await ranLaws({ language: "java" }, java,
    '<testsuite><testcase name="lawLaw2_example0()" classname="example.UnitLawSpecTest"/></testsuite>'), [2]);
  const js = [law(0, "test/u.lawspec.test.mjs", "example.unit::a & b")];
  assert.deepEqual(await ranLaws({ language: "javascript" }, js,
    '<testsuites><testcase name="example.unit::a &amp; b property" classname="test"/></testsuites>'), [0]);
});

test("reads Go events, Rust results and hspec examples", async () => {
  const go = [law(0, "example/unit/lawspec_test.go", undefined, "go"), law(1, "example/unit/lawspec_test.go", undefined, "go")];
  assert.deepEqual(await ranLaws({ language: "go" }, go, undefined,
    '{"Action":"run","Test":"TestLaw1_Property"}\n{"Action":"pass","Test":"TestLaw0_Example0","Package":"p"}\n'), [0]);
  const rust = [law(0, "tests/u_lawspec.rs", undefined, "rust"), law(3, "tests/u_lawspec.rs", undefined, "rust")];
  assert.deepEqual(await ranLaws({ language: "rust" }, rust, undefined,
    "running 1 test\ntest law_law_3 ... ok\n\ntest result: ok. 1 passed\n"), [3]);
  const haskell = [law(0, "test/Example/UnitSpec.hs", undefined, "haskell"), law(1, "test/Example/OtherSpec.hs", undefined, "haskell")];
  assert.deepEqual(await ranLaws({ language: "haskell" }, haskell, undefined,
    "Example.Unit\n  lawLaw0_example0 [✔]\n  lawLaw0_property: example.unit::law 0 [✔]\nExample.Other\n\nFinished in 0.01 seconds\n2 examples, 0 failures\n"), [0]);
});

test("a changed recording changes the recordings' digest", async () => {
  const folder = await mkdtemp(path.join(os.tmpdir(), "lawspec-recorded-"));
  try {
    assert.equal(await recordedDigest(path.join(folder, "absent")), "");
    await mkdir(path.join(folder, "example.unit"), { recursive: true });
    await writeFile(path.join(folder, "example.unit", "first"), "1\n");
    const before = await recordedDigest(folder);
    assert.notEqual(before, "");
    await writeFile(path.join(folder, "example.unit", "first"), "2\n");
    assert.notEqual(await recordedDigest(folder), before);
  } finally {
    await rm(folder, { recursive: true, force: true });
  }
});

test("runs pytest-xdist for a parallel unit's laws when it is installed", () => {
  const entry = { ...law(1, "tests/test_example_unit_lawspec.py"), parallel: true };
  assert.ok(invocations({ language: "python" }, [entry], { xdist: true })[0].args.includes("-n"));
  assert.ok(!invocations({ language: "python" }, [entry])[0].args.includes("-n"));
  assert.ok(!invocations({ language: "python" }, [law(1, "tests/test_example_unit_lawspec.py")], { xdist: true })[0].args.includes("-n"));
});

test("selects a target's JavaScript tests, replay and search included, by label", () => {
  const run = invocations({ language: "javascript" }, [law(1, "test/example_unit.lawspec.test.mjs", "example.unit::law 1", "javascript")]);
  const pattern = new RegExp(run[0].args.find((a) => a.startsWith("--test-name-pattern=")).slice("--test-name-pattern=".length));
  for (const name of ["example.unit::law 1 property", "example.unit::law 1 replay", "example.unit::law 1 search"])
    assert.ok(pattern.test(name), name);
});

test("runs the harness's benchmarks by the names the manifest gives", () => {
  const bench = (name, file) => ({ unit: "example.unit", benchmark: "a booking", file, name });
  assert.deepEqual(benchmarkInvocations({ language: "python" }, []), []);
  const python = benchmarkInvocations({ language: "python" }, [bench("test_benchmark__a_booking", "tests/test_example_unit_lawspec.py")]);
  assert.deepEqual(python[0].args.slice(-2), ["-k", "test_benchmark__a_booking"]);
  const go = benchmarkInvocations({ language: "go" }, [bench("TestBenchmarkABooking", "example/unit/lawspec_test.go")]);
  assert.deepEqual(go[0].args.slice(-2), ["-run", "^(TestBenchmarkABooking)$"]);
  const rust = benchmarkInvocations({ language: "rust" }, [bench("benchmark_a_booking", "tests/example_unit_lawspec.rs")]);
  assert.equal(rust[0].args.at(-1), "benchmark_a_booking");
  const haskell = benchmarkInvocations({ language: "haskell" }, [bench("benchmark a booking", "test/Example/UnitSpec.hs")]);
  assert.match(haskell[0].args.at(-1), /--match Example\.Unit\/benchmark/);
});

// ref:REQ-harness-units ref:DEC-native-property-frameworks
test("selects exact BEAM benchmarks with native commands and structured Gleam selection", () => {
  const entry = (name, file) => ({ unit: "example.unit", benchmark: name, name, file });
  const erlang = benchmarkInvocations({ language: "erlang" }, [entry("benchmark_work", "checks/example_unit_lawspec_tests.erl")]);
  assert.deepEqual(erlang, [{ command: "rebar3", args: ["eunit", "--generator", "example_unit_lawspec_tests:benchmark_work_cases"] }]);
  const elixir = benchmarkInvocations({ language: "elixir" }, [
    entry("benchmark_work", "checks/example_unit_lawspec_test.exs"), entry("benchmark_work_2", "checks/example_unit_lawspec_test.exs")]);
  assert.deepEqual(elixir, [{ command: "mix", args: ["test", "checks/example_unit_lawspec_test.exs",
    "--only", "lawspec:benchmark_work", "--only", "lawspec:benchmark_work_2"] }]);
  const gleam = benchmarkInvocations({ language: "gleam" }, [entry("benchmark_work", "test/example_unit_lawspec_test.gleam")]);
  assert.deepEqual(gleam[0].args, ["test", "--target", "erlang"]);
  assert.deepEqual(JSON.parse(gleam[0].env.LAWSPEC_BEAM_BENCHMARKS),
    [{ module: "example_unit_lawspec_test", function: "benchmark_work__case_0_test" }]);
});

// ref:DEC-never-pass-vacuously ref:DEC-native-property-frameworks
test("selects BEAM laws once across units with exact identities", () => {
  const entries = [{...law(0, "test/a_test.exs"), name:"law_same"},
    {...law(1, "test/b_test.exs"), unit:"example.other", name:"law_same"}];
  for (const language of ["erlang", "elixir", "gleam"]) {
    const [run] = invocations({language}, entries, {scratch:"reports"});
    assert.equal(run.laws, entries);
    assert.equal(run.report.run, run.env.LAWSPEC_BEAM_RUN);
    assert.equal(run.report.file, run.env.LAWSPEC_BEAM_REPORT);
    assert.notEqual(run.report.run, invocations({language}, entries)[0].report.run);
    assert.deepEqual(run.ran({identity:"example.other::law_same",status:"passed"}), [entries[1]]);
    assert.deepEqual(run.ran({identity:"example.other::law_same_2",status:"passed"}), []);
    assert.deepEqual(run.ran({identity:"example.other::law_same",status:"failed"}), []);
    assert.deepEqual(invocations({language}, []), []);
    if (language === "elixir")
      assert.deepEqual(run.args, ["test", "test/a_test.exs", "test/b_test.exs",
        "--only", "lawspec_identity:example.unit::law_same", "--only", "lawspec_identity:example.other::law_same"]);
    else
      assert.deepEqual(JSON.parse(run.env.LAWSPEC_BEAM_LAWS), entries.map(({unit,name})=>({unit,name})));
  }
});

test("BEAM coverage exports are unique per native run and honor Mix's output directory", () => {
  const entries = [{...law(0, "test/a_test.exs"), name: "law_same"}];
  const root = path.resolve("project with spaces");
  const coverage = path.join(root, ".lawspec/coverage");
  const coverageConfig = {tool: "Mix.Tasks.Test.Coverage", output: path.join(root, "custom coverage"),
    compilePath: path.join(root, "custom build/app/ebin")};
  for (const language of ["erlang", "elixir", "gleam"]) {
    const [run] = invocations({language}, entries, {root, coverage, coverageConfig});
    assert.equal(run.coverage.run, run.report.run);
    assert.equal(run.coverage.file, path.join(coverage, "runs", `${run.report.run}.coverdata`));
    assert.notEqual(run.coverage.file, invocations({language}, entries, {root, coverage, coverageConfig})[0].coverage.file);
    if (language === "elixir") {
      assert.equal(run.coverage.beamDirectory, coverageConfig.compilePath);
      assert.deepEqual(run.args.slice(-3, -1), ["--cover", "--export-coverage"]);
      assert.equal(path.resolve(coverageConfig.output, run.args.at(-1)) + ".coverdata", run.coverage.file);
    } else if (language === "erlang") {
      assert.equal(run.coverage.tool, "rebar3");
      assert.deepEqual(run.args.slice(-3, -1), ["--cover", "--cover_export_name"]);
      assert.equal(run.args.at(-1) + ".coverdata", run.coverage.file);
    } else assert.deepEqual(JSON.parse(run.env.LAWSPEC_BEAM_COVERAGE), run.coverage);
    assert.equal(invocations({language}, entries)[0].coverage, undefined);
    assert.deepEqual(invocations({language}, [], {coverage, coverageConfig}), []);
  }
  assert.throws(() => invocations({language: "elixir"}, entries, {coverage}), /effective output directory/);
  assert.throws(() => invocations({language: "elixir"}, entries,
    {coverage, coverageConfig: {...coverageConfig, tool: "Other.Coverage"}}), /Mix.Tasks.Test.Coverage/);
});

test("accepts only sealed native reports for this BEAM invocation", async () => {
  const scratch = await mkdtemp(path.join(os.tmpdir(), "lawspec-beam-report-"));
  try {
    const [invocation] = invocations({language:"erlang"}, [{...law(0,"test/a.erl"), name:"law_a"}], {scratch});
    const {run, file} = invocation.report;
    const row = {event:"test", run, name:'case "雪"', classname:"example", identity:"example.unit::law_a", status:"passed", time:0.01};
    const rows = [{event:"start",run}, row, {...row, name:"failed", status:"failed", failure:"native <failure>"}, {event:"end",run}];
    await writeFile(file, rows.map(row=>JSON.stringify(row)).join("\n")+"\n");
    const tests = await executedTests(invocation.report, "", scratch, 0);
    assert.equal(tests.length,2);
    assert.equal(tests[1].status,"failed");
    const xml = junitFromTests(tests);
    assert.match(xml,/tests="2" failures="1"/);
    assert.match(xml,/native &lt;failure&gt;/);
    assert.match(xml,/time="0.01"/);
    for (const invalid of [[], rows.slice(0,-1), rows.slice(1),
      rows.map(row=>({...row,run:"old"})), [rows[0], {...row, status:"skipped"}, rows.at(-1)],
      [rows[0], {...row, time:-1}, rows.at(-1)], [rows[0], {...row, identity:null}, rows.at(-1)]]) {
      await writeFile(file, invalid.map(row=>JSON.stringify(row)).join("\n"));
      assert.deepEqual(await executedTests(invocation.report,"",scratch,0),[]);
    }
    await writeFile(file,"{truncated\n");
    assert.deepEqual(await executedTests(invocation.report,"",scratch,0),[]);
  } finally { await rm(scratch,{recursive:true,force:true}); }
});

test("BEAM cache keys include toolchain manifests and exclude compiled dependencies", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "lawspec-beam-cache-"));
  try {
    for (const file of ["rebar.lock","mix.lock","manifest.toml"]) {
      const before = await environmentDigest(root,{});
      await writeFile(path.join(root,file),"changed lock\n");
      assert.notEqual(await environmentDigest(root,{}),before);
    }
    const before = await projectDigest(root,new Set());
    for (const dir of ["_build","deps","build"]) {
      await mkdir(path.join(root,dir));
      await writeFile(path.join(root,dir,"ignored"),"generated dependency\n");
    }
    assert.equal(await projectDigest(root,new Set()),before);
    await writeFile(path.join(root,"adapter.erl"),"changed adapter\n");
    assert.notEqual(await projectDigest(root,new Set()),before);
  } finally { await rm(root,{recursive:true,force:true}); }
});
