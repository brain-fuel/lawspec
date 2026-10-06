import { test } from "node:test";
import assert from "node:assert/strict";
import { benchmarkInvocations, invocations, lawKeys, recordedDigest, selectByTags, mergeJunit, junitFromTests } from "../test-command.mjs";

// A manifest entry, named as each target names a law's tests (LawSpec.TestNames).
const names = { python: (i) => `test_law_${i}`, go: (i) => `TestLaw${i}`, rust: (i) => `law_law_${i}` };
const law = (index, file, label = `example.unit::law ${index}`, language = "python") =>
  ({ law: `example.unit::law::law ${index}`, unit: "example.unit", label, index, file, key: `k${index}`, callsAdapters: true,
    name: (names[language] ?? ((i) => `lawLaw${i}`))(index), tags: [] });

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
