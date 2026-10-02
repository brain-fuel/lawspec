import { test } from "node:test";
import assert from "node:assert/strict";
import { invocations, lawKeys } from "../test-command.mjs";

const law = (index, file, label = `example.unit::law ${index}`) =>
  ({ law: `example.unit::law::law ${index}`, unit: "example.unit", label, index, file, key: `k${index}`, callsAdapters: true });

test("selects whole test names, so law 1 never selects law 10", () => {
  const python = invocations({ language: "python" }, [law(1, "tests/test_example_unit_lawspec.py")]);
  assert.deepEqual(python[0].args.slice(-2), ["-k", "test_law1_"]);
  const go = invocations({ language: "go" }, [law(1, "example/unit/lawspec_test.go"), law(10, "example/unit/lawspec_test.go")]);
  assert.equal(go.length, 1);
  assert.match("TestLaw10Property", new RegExp(go[0].args.at(-1)));
  assert.doesNotMatch("TestLaw10Property", new RegExp(go[0].args.at(-1).replace("1|10", "1")));
  const rust = invocations({ language: "rust" }, [law(1, "tests/example_unit_lawspec.rs")]);
  assert.deepEqual(rust[0].args, ["test", "--test", "example_unit_lawspec", "--", "--exact", "test_1"]);
  const kotlin = invocations({ language: "kotlin" }, [law(1, "src/test/kotlin/example/UnitLawSpecTest.kt")]);
  const pattern = new RegExp(`^${kotlin[0].env["kotest.filter.tests"].replace("*", ".*?")}$`);
  assert.ok(pattern.test("law1Property: example.unit::law 1"));
  assert.ok(!pattern.test("law10Example0"));
  assert.deepEqual(kotlin[0].args.slice(-2), ["--tests", "example.UnitLawSpecTest"]);
});

test("runs each unit's laws separately where names repeat across units", () => {
  const entries = [law(0, "tests/test_a_lawspec.py"), law(0, "tests/test_b_lawspec.py")];
  assert.equal(invocations({ language: "python" }, entries).length, 2);
  const java = invocations({ language: "java" }, [law(0, "src/test/java/a/ALawSpecTest.java"), law(2, "src/test/java/b/BLawSpecTest.java")]);
  assert.equal(java.length, 1);
  assert.equal(java[0].args.at(-1), "-Dtest=a.ALawSpecTest#law0Example*+law0Boundary*+law0Property*,b.BLawSpecTest#law2Example*+law2Boundary*+law2Property*");
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
  const haskell = invocations({ language: "haskell" }, [law(3, "test/Example/UnitSpec.hs")]);
  assert.match(haskell[0].args.at(-1), /--match Example\.Unit\/law3Property/);
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
