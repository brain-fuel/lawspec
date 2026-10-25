// Generated from templates/npm/test/test-command.test.mjs by lawspec-dev generate. Do not edit.
import { test } from "node:test";
import assert from "node:assert/strict";
import { benchmarkInvocations, configurationInvocations, preparationInvocations, presentationInvocations, presentationDigest, invocations, lawKeys, recordedDigest, selectByTags, mergeJunit, junitFromTests,
  environmentDigest, projectDigest, testsToRun, previousResult, executedTests } from "../test-command.mjs";

// A manifest entry, named as each target names a law's tests (LawSpec.TestNames).
const names = { python: (i) => `test_law_${i}`, go: (i) => `TestLaw${i}`, rust: (i) => `law_law_${i}` };
const law = (index, file, label = `example.unit::law ${index}`, language = "python") =>
  ({ law: `example.unit::law::law ${index}`, unit: "example.unit", label, index, file, key: `k${index}`, callsAdapters: true,
    name: (names[language] ?? ((i) => `lawLaw${i}`))(index), tags: [] });

test("numbered finite cases select and report exactly their JavaScript law", () => {
  for (const language of ["javascript", "typescript"]) {
    const first = law(1, "test/example.test.mjs");
    const neighbor = law(10, "test/example.test.mjs");
    const runs = invocations({language}, [first, neighbor]);
    const run = runs.at(-1);
    assert.deepEqual(run.matches({name: `${first.label} boundary 256`, status: "passed"}), [first]);
    assert.deepEqual(run.ran({name: `${first.label} boundary 256`, status: "failed"}), []);
    assert.deepEqual(run.matches({name: `${neighbor.label} boundary 1`, status: "passed"}), [neighbor]);
    assert.deepEqual(run.matches({name: `${first.label} boundary wrong`, status: "passed"}), []);
    const selection = new RegExp(run.args.find(arg => arg.startsWith("--test-name-pattern=")).slice("--test-name-pattern=".length));
    assert.match(`${first.label} boundary 256`, selection);
  }
});

test("layout changes only the validation digest, while profile and toolchain change execution keys",()=>{
  const input={build:'compiler',target:{language:'javascript'},machineBits:64,tests:[law(1,'test/a')],environment:'node22',project:'adapter'};
  const key=lawKeys({...input,minify:false});
  assert.deepEqual(lawKeys({...input,minify:true}),key);
  assert.notDeepEqual(lawKeys({...input,machineBits:32}),key);
  assert.notDeepEqual(lawKeys({...input,environment:'node23'}),key);
  assert.notDeepEqual(lawKeys({...input,project:'changed-adapter'}),key);
  assert.notEqual(presentationDigest([{path:'test/a',ownership:'generated',content:'old'}],'node22'),
    presentationDigest([{path:'test/a',ownership:'generated',content:'new'}],'node22'));
  assert.deepEqual(presentationInvocations({language:'javascript'},[{path:'test/a.mjs'},{path:'src/a.mjs'}]),[
    {command:'node',args:['--check','test/a.mjs'],environment:{}},
    {command:'node',args:['--check','src/a.mjs'],environment:{}}]);
  assert.deepEqual(presentationInvocations({language:'rust'},[],{offline:true})[0].args,['test','--no-run','--offline']);
});

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

test("an environment attestation inside the project is not a project input", async t => {
  const {mkdtemp, writeFile, rm} = await import("node:fs/promises");
  const {default: os} = await import("node:os");
  const {default: path} = await import("node:path");
  const root = await mkdtemp(path.join(os.tmpdir(), "lawspec-attestation-digest-"));
  t.after(() => rm(root, {recursive: true, force: true}));
  await writeFile(path.join(root, "adapter.py"), "def f(): pass\n");
  const attestation = (status) => JSON.stringify({format: "environment-attestation", version: 1, execution: {status}});
  await writeFile(path.join(root, "run-attestation.json"), attestation("running"));
  const before = await projectDigest(root, new Set());
  await writeFile(path.join(root, "run-attestation.json"), attestation("completed"));
  assert.equal(await projectDigest(root, new Set()), before);
  await writeFile(path.join(root, "settings.json"), JSON.stringify({format: "other"}));
  assert.notEqual(await projectDigest(root, new Set()), before);
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
  assert.deepEqual(rust[0].args, ["test", "--test", "example_unit_lawspec", "--", "law_law_1::"]);
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
  // Scala 3 instruments the sources, not the tests, into the coverage data.
  const scala = invocations({ language: "scala" }, [law(0, "src/test/scala/a/BLawSpecTest.scala", undefined, "scala")], { coverage: "c" });
  assert.ok(scala[0].args.includes(`-coverage-out:${path.resolve("c", "data")}`));
  assert.ok(scala[0].args.some((arg) => arg.startsWith("-coverage-exclude-files:") && arg.includes("src/test/scala")));
});

test("runs each unit's laws separately where names repeat across units", () => {
  const entries = [law(0, "tests/test_a_lawspec.py"), law(0, "tests/test_b_lawspec.py")];
  assert.equal(invocations({ language: "python" }, entries).length, 2);
  const java = invocations({ language: "java" }, [law(0, "src/test/java/a/ALawSpecTest.java", undefined, "java"), law(2, "src/test/java/b/BLawSpecTest.java", undefined, "java")]);
  assert.equal(java.length, 1);
  assert.equal(java[0].args.at(-1), "-Dtest=a.ALawSpecTest#lawLaw0_*,b.BLawSpecTest#lawLaw2_*");
});

test("law and benchmark invocations clear inherited JVM finite-case selection", () => {
  for (const [language, file] of [["java", "src/test/java/example/UnitLawSpecTest.java"],
    ["groovy", "src/test/groovy/example/UnitLawSpec.groovy"]]) {
    const entry = law(0, file, undefined, language);
    for (const run of [...invocations({language}, [entry]), ...benchmarkInvocations({language}, [entry])])
      assert.equal({...{LAWSPEC_CASE: "7"}, ...run.env}.LAWSPEC_CASE, "");
  }
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

test("compiler-resolved native codecs and generators affect only their dependent laws", () => {
  const bound={...law(0,"t"),callsAdapters:true},independent={...law(1,"t"),callsAdapters:false};
  const unknown={...law(2,"t")};delete unknown.callsAdapters;
  for(const nativeBindings of [{types:[{type:"unit::Value",native:["Value"]}]},
    {generators:[{type:"unit::Value",factory:["makeValue"]}]}]) {
    const keys=project=>lawKeys({build:"b",target:{language:"python",nativeBindings},machineBits:64,
      tests:[bound,independent,unknown],environment:"e",project});
    const before=keys("first implementation"),after=keys("changed implementation");
    assert.notEqual(before.get(bound.law),after.get(bound.law));
    assert.equal(before.get(independent.law),after.get(independent.law));
    assert.notEqual(before.get(unknown.law),after.get(unknown.law),'unknown compiler flags remain conservative');
  }
});

test("generated name overrides affect pure presentation and preserve native API dependencies", () => {
  const tests=[{...law(0,"t"),callsAdapters:false},law(1,"t")];
  const keys=name=>lawKeys({build:"b",target:{language:"python",nativeBindings:{names:[{declaration:"unit::double",name}]}},
    machineBits:64,tests,environment:"e",project:"p"});
  assert.equal(keys("first").get(tests[0].law),keys("renamed").get(tests[0].law));
  assert.notEqual(keys("first").get(tests[1].law),keys("renamed").get(tests[1].law));
});

test("a law's key ignores the generated file's bytes", () => {
  const tests = [law(0, "t")];
  const keys = (content) => lawKeys({ build: "b", target: { language: "python" }, machineBits: 64, minify: false,
    tests, files: [{ path: "t", content }], environment: "e", project: "p" });
  assert.equal(keys("# law at line 3\n").get(tests[0].law), keys("# law at line 9, reworded\n").get(tests[0].law));
  const changed = lawKeys({ build: "b", target: { language: "python" }, machineBits: 64, minify: false,
    tests: [{ ...law(0, "t"), key: "another" }], environment: "e", project: "p" });
  assert.notEqual(changed.get(tests[0].law), keys("").get(tests[0].law));
});

test("a renamed law finds its result by its key", () => {
  const entry = { ...law(0, "t"), law: "example.unit::law::renamed" };
  const previous = { "example.unit::law::original": { key: "k", seed: "1" } };
  assert.deepEqual(testsToRun([entry], new Map([[entry.law, "k"]]), previous, {}), []);
  assert.equal(testsToRun([entry], new Map([[entry.law, "other"]]), previous, {}).length, 1);
  assert.deepEqual(previousResult(previous, entry.law, "k"), { key: "k", seed: "1" });
});

import { mkdtemp, mkdir, writeFile, rm, symlink } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

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
});

test('Node structured reports preserve phrase names and literal XML entities without confusing identities',async()=>{
  const {spawnSync}=await import('node:child_process');
  const {readFile}=await import('node:fs/promises');
  const scratch=await mkdtemp(path.join(os.tmpdir(),'lawspec-node-events-'));
  try {
    const labels=['example.unit::|a " & 雪|','example.unit::|a &quot; & 雪|',
      'example.unit::|skipped|','example.unit::|todo|','example.unit::|failed|'];
    const file=path.join(scratch,'native.test.mjs');
    await writeFile(file,"import {test} from 'node:test';\n"+
      `test(${JSON.stringify(labels[0])},()=>{});\n`+
      `test(${JSON.stringify(labels[1])},()=>{});\n`+
      `test.skip(${JSON.stringify(labels[2])},()=>{});\n`+
      `test.todo(${JSON.stringify(labels[3])});\n`+
      `test(${JSON.stringify(labels[4])},()=>{throw new Error('native <failure>')});\n`);
    const entries=labels.map((label,index)=>law(index,file,label));
    const [run]=invocations({language:'javascript'},entries,{scratch});
    assert.equal(run.report.kind,'node-events');
    const child=spawnSync(run.command,run.args,{env:{...process.env,...run.env},encoding:'utf8'});
    assert.equal(child.status,1,'The deliberately failing native test must fail\n'+child.stdout+child.stderr);
    const tests=await executedTests(run.report,child.stdout+child.stderr,scratch,0);
    assert.deepEqual(tests.map(test=>test.name),labels);
    assert.deepEqual(tests.map(test=>test.status),['passed','passed','skipped','skipped','failed']);
    assert.deepEqual(tests.flatMap(run.ran).map(entry=>entry.index),[0,1]);
    const xmlFile=path.join(scratch,'projected.xml');
    await writeFile(xmlFile,junitFromTests(tests));
    const xml=await executedTests({kind:'junit',files:[xmlFile]},'',scratch,0);
    assert.deepEqual(xml.map(test=>test.name),labels);
    assert.deepEqual(xml.map(test=>test.status),['passed','passed','skipped','skipped','failed']);
    const rows=(await readFile(run.report.file,'utf8')).trim().split('\n').map(line=>JSON.parse(line));
    for(const invalid of [rows.slice(0,-1),rows.slice(1),rows.map(row=>({...row,run:'old'})),
      rows.map(row=>({...row,version:2})),[rows[0],{...rows[1],time:-1},rows.at(-1)],
      [...rows.slice(0,-1),{...rows.at(-1),count:0}]]) {
      await writeFile(run.report.file,invalid.map(row=>JSON.stringify(row)).join('\n'));
      assert.deepEqual(await executedTests(run.report,'',scratch,0),[]);
    }
    await writeFile(run.report.file,rows.map(row=>JSON.stringify(row)).join('\n'));
    const [next]=invocations({language:'javascript'},entries,{scratch});
    assert.notEqual(next.report.run,run.report.run);
    assert.deepEqual(await executedTests(next.report,'',scratch,0),[],'A previous report is not fresh execution evidence');
  } finally {await rm(scratch,{recursive:true,force:true});}
});

test("Go finite containers do not stand for executed cases", async () => {
  const entry = law(1, "example/unit/lawspec_test.go", undefined, "go");
  const [run] = invocations({language: "go"}, [entry]);
  const parent = {name: "TestLaw1_Boundaries", status: "passed"};
  const child = {name: "TestLaw1_Boundaries/Boundary256", status: "passed"};
  assert.deepEqual(run.matches(parent), []);
  assert.deepEqual(run.ran(parent), []);
  assert.deepEqual(run.matches(child), [entry]);
  assert.deepEqual(run.ran(child), [entry]);
  assert.deepEqual(run.ran({...child, status: "failed"}), []);
  assert.deepEqual(await ranLaws({language: "go"}, [entry], undefined,
    JSON.stringify({Action: "pass", Test: parent.name, Package: "p"}) + "\n"), []);
});

test("reads Go events, Rust results and hspec examples", async () => {
  const go = [law(0, "example/unit/lawspec_test.go", undefined, "go"), law(1, "example/unit/lawspec_test.go", undefined, "go")];
  assert.deepEqual(await ranLaws({ language: "go" }, go, undefined,
    '{"Action":"run","Test":"TestLaw1_Property"}\n{"Action":"pass","Test":"TestLaw0_Example0","Package":"p"}\n'), [0]);
  const rust = [law(0, "tests/u_lawspec.rs", undefined, "rust"), law(3, "tests/u_lawspec.rs", undefined, "rust")];
  assert.deepEqual(await ranLaws({ language: "rust" }, rust, undefined,
    "running 2 tests\ntest law_law_3::example_1 ... ok\ntest law_law_3::property ... ok\ntest law_law_30::property ... ok\n\ntest result: ok. 3 passed\n"), [3]);
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
    await symlink("first",path.join(folder,"example.unit","linked"));
    await assert.rejects(recordedDigest(folder),/Recording input is a symbolic link/);
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
    [{ module: "example_unit_lawspec_test", function: "benchmark_work_test" }]);
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

test("an attested law's key follows how its dependencies were wired; others keep theirs", () => {
  const files = [{ path: "t", content: "x" }];
  const keys = (attested) => lawKeys({ build: "b", target: { language: "python" }, machineBits: 64, minify: false,
    tests: [law(0, "t"), law(1, "t")], files, environment: "e", project: "p", attested });
  const plain = keys(undefined);
  const standIn = keys(new Map([["example.unit::law::law 0", '["staging",[{"kind":"stand-in"}]]']]));
  const real = keys(new Map([["example.unit::law::law 0", '["staging",[{"kind":"real"}]]']]));
  assert.notEqual(standIn.get("example.unit::law::law 0"), plain.get("example.unit::law::law 0"));
  assert.notEqual(standIn.get("example.unit::law::law 0"), real.get("example.unit::law::law 0"));
  assert.equal(standIn.get("example.unit::law::law 1"), plain.get("example.unit::law::law 1"));
});

test("selects Swift laws with test id filters and reads them back by suite and function", async () => {
  const swift = [law(1, "tests/LawSpec/ExampleUnit.swift", undefined, "swift"), law(10, "tests/LawSpec/ExampleUnit.swift", undefined, "swift")];
  const [run] = invocations({ language: "swift" }, swift, { scratch: "s" });
  assert.equal(run.command, "swift");
  assert.deepEqual(run.args.slice(0, 3), ["test", "--filter", "ExampleUnit/lawLaw1(_[A-Za-z0-9]+)?\\("]);
  assert.ok(run.args.includes("--xunit-output"));
  assert.deepEqual(await ranLaws({ language: "swift" }, swift,
    '<testsuites><testsuite><testcase name="lawLaw1_property()" classname="AppTests.LawSpecTests.ExampleUnit"/>' +
    '<testcase name="lawLaw10_example0()" classname="AppTests.ExampleUnit"/>' +
    '<testcase name="lawLaw1_property()" classname="AppTests.LawSpecTests.OtherUnit"/></testsuite></testsuites>'), [1, 10]);
  const coverage = invocations({ language: "swift" }, [law(1, "tests/LawSpec/ExampleUnit.swift")], { coverage: "c" });
  assert.ok(coverage[0].args.includes("--enable-code-coverage"));
  const bench = benchmarkInvocations({ language: "swift" }, [{ unit: "example.unit", benchmark: "a booking", file: "tests/LawSpec/ExampleUnit.swift", name: "benchmarkABooking" }]);
  assert.deepEqual(bench[0].args, ["test", "--filter", "/benchmarkABooking\\(", "--filter", "ExampleUnit/ordered\\("]);
  assert.deepEqual(JSON.parse(bench[0].env.LAWSPEC_SWIFT_LAWS), [{unit:"example.unit",name:"benchmarkABooking"}]);
  assert.equal(bench[0].env.LAWSPEC_SWIFT_REPORT, "");
  assert.deepEqual(run.env, {LAWSPEC_SWIFT_LAWS:"[]",LAWSPEC_SWIFT_REPORT:"",LAWSPEC_SWIFT_RUN:""});
});

// These are protocol fixtures rather than generated source: Swift's runtime
// produces them and its framework independently seals their aggregate in XML.
async function swiftReport(entries, change = () => {}, xmlChange = (xml) => xml) {
  const scratch = await mkdtemp(path.join(os.tmpdir(), "lawspec-swift-events-"));
  try {
    const [run] = invocations({language:"swift"}, entries, {scratch});
    const rows = [], units = new Map();
    for (const entry of entries.filter((entry) => entry.scope === "ordered")) {
      const cases = Array.from({length:entry.knownDiscrepancy ? 1 : entry.coverage?.cases ?? 1}, (_,index) =>
        ({law:entry.name,name:entry.name+"_boundary",id:entry.name+"#"+index}));
      units.set(entry.unit,[...(units.get(entry.unit)??[]),...cases]);
    }
    for (const [unit,cases] of units) {
      rows.push({event:"plan",unit,cases});
      for (const item of cases) {
        rows.push({event:"case-start",unit,...item});
        rows.push({event:"case-end",unit,...item,status:"passed",time:0.01});
      }
    }
    for (const row of rows) Object.assign(row,{version:1,run:run.report.run});
    change(rows,run);
    const suites = [...new Set(entries.filter((entry) => entry.scope === "ordered")
      .map((entry) => path.posix.basename(entry.file,".swift")))];
    const xml = '<testsuites><testsuite>'+suites.map((suite) =>
      `<testcase classname="AppTests.${suite}" name="ordered(_:)" time="0.1"/>`).join("")+
      entries.filter((entry) => entry.scope !== "ordered").map((entry) =>
        `<testcase classname="AppTests.${path.posix.basename(entry.file,".swift")}" name="${entry.name}()"/>`).join("")+
      '</testsuite></testsuites>';
    await writeFile(run.report.file,rows.map((row) => JSON.stringify(row)).join("\n"));
    const changed = xmlChange(xml);
    if (changed !== null) await writeFile(run.report.files[0],changed);
    return {run,tests:await executedTests(run.report,"",scratch,0)};
  } finally { await rm(scratch,{recursive:true,force:true}); }
}
const orderedSwift = (index, cases = 3) => ({...law(index,"tests/LawSpec/ExampleUnit.swift",undefined,"swift"),
  scope:"ordered",coverage:{kind:"finite-inputs",cases,scopedQuantifiers:false}});

test("Swift ordered groups select whole laws and attribute individually completed cases", async () => {
  const first = orderedSwift(1), second = orderedSwift(10,2);
  const ordinary = {...law(2,"tests/LawSpec/OtherUnit.swift",undefined,"swift"),obligations:[{stage:"model"}]};
  const {run,tests} = await swiftReport([first,second,ordinary],(rows) => rows.push({...rows[0]}));
  assert.equal(run.report.kind,"swift-events");
  assert.deepEqual(run.args.slice(0,5),["test","--filter","ExampleUnit/ordered\\(","--filter","OtherUnit/lawLaw2(_[A-Za-z0-9]+)?\\("]);
  assert.deepEqual(JSON.parse(run.env.LAWSPEC_SWIFT_LAWS),[first,second].map(({unit,name}) => ({unit,name})));
  assert.equal(run.env.LAWSPEC_SWIFT_RUN,run.report.run);
  assert.equal(run.env.LAWSPEC_SWIFT_REPORT,run.report.file);
  assert.ok(path.isAbsolute(run.report.file));
  assert.ok(run.report.files[0].includes(run.report.run));
  assert.equal(tests.length,6);
  assert.deepEqual(tests.filter((test) => test.identity).map((test) => test.name),
    ["lawLaw1#0","lawLaw1#1","lawLaw1#2","lawLaw10#0","lawLaw10#1"]);
  assert.deepEqual(tests.flatMap(run.ran),[ordinary,first,first,first,second,second]);
  assert.deepEqual(run.matches({unit:first.unit,nativeName:first.name,status:"failed"}),[first]);
  assert.deepEqual(run.ran({unit:first.unit,nativeName:first.name,status:"failed"}),[]);
  assert.match(junitFromTests(tests),/name="lawLaw1#2"/);
  const [next] = invocations({language:"swift"},[first]);
  assert.notEqual(run.report.run,next.report.run);
});

test("Swift ordered reports reject malformed, stale, partial or unplanned execution", async () => {
  const entry = orderedSwift(1);
  const mutations = [
    (rows) => rows.splice(0),
    (rows) => {rows[0].version=2;},
    (rows) => {rows[1].run="stale";},
    (rows) => rows.pop(),
    (rows) => rows.splice(1,1),
    (rows) => {rows[0].cases=[];},
    (rows) => {rows[0].cases[0].law="unknown";},
    (rows) => {rows[0].cases[1].id=rows[0].cases[0].id;},
    (rows) => {rows[1].id="unknown";},
    (rows) => {rows[1].law="unknown";},
    (rows) => {rows[1].name="wrong name";},
    (rows) => rows.push({...rows[1]}),
    (rows) => rows.push({...rows[2]}),
    (rows) => {rows[2].status="skipped";},
    (rows) => {rows[2].time=-1;},
    (rows) => {rows[2].time="0.1";},
    (rows) => {delete rows[2].time;},
    (rows) => {rows[2].failure=5;},
    (rows) => {rows[2].event="unknown";},
    (rows) => rows.push({...rows[0],cases:rows[0].cases.slice(1)}),
    (rows) => {rows[0].cases.pop();rows.splice(-2);},
    (rows) => {rows[0].unit="other";},
  ];
  for (const [index,change] of mutations.entries()) {
    const {tests}=await swiftReport([entry],change);
    assert.deepEqual(tests,[],`invalid lifecycle ${index} credited a case`);
  }
  for (const xmlChange of [() => null,() => "",(xml) => xml.replaceAll("ExampleUnit","WrongSuite"),
    (xml) => xml.replace("ordered(_:)","other(_:)")]) {
    const {run,tests} = await swiftReport([entry],undefined,xmlChange);
    assert.deepEqual(tests.flatMap(run.ran),[]);
  }
});

test("Swift concrete failures and framework failures cannot become positive law evidence", async () => {
  const first = orderedSwift(1), second = orderedSwift(10,1);
  const failedXml = (xml) => xml.replace('time="0.1"/>','time="0.1"><failure message="native failure"/></testcase>');
  const markFailure = (rows) => {rows[2].status="failed";rows[2].failure="case failure";};
  assert.deepEqual((await swiftReport([first],markFailure)).tests,[]);
  const failed = await swiftReport([first,second],markFailure,failedXml);
  assert.equal(failed.tests[0].status,"failed");
  assert.equal(failed.tests[0].failure,"case failure");
  assert.equal(failed.tests[1].status,"passed");
  const outside = await swiftReport([first],undefined,failedXml);
  assert.ok(outside.tests.every((test) => test.status === "incomplete"));
  assert.deepEqual(outside.tests.flatMap(outside.run.ran),[]);
  assert.match(junitFromTests(outside.tests),/lawspec.status/);
  const ordinary = law(2,"tests/LawSpec/OtherUnit.swift",undefined,"swift");
  const mixed = await swiftReport([first,ordinary],(rows) => rows.pop());
  assert.deepEqual(mixed.tests.flatMap(mixed.run.ran),[ordinary]);
  const known = {...orderedSwift(1,100),knownDiscrepancy:"tracked failure"};
  assert.equal((await swiftReport([known])).tests.length,1);
  const sampled = {...orderedSwift(1),coverage:{kind:"sampled",scopedQuantifiers:true}};
  assert.equal((await swiftReport([sampled])).tests.length,1);
});

test("selects .NET laws with xUnit query filters and reads them back by display name", async () => {
  const fsharp = [law(1, "tests/LawSpec/ExampleUnit.fs", undefined, "fsharp"), law(10, "tests/LawSpec/ExampleUnit.fs", undefined, "fsharp")];
  const [run] = invocations({ language: "fsharp" }, fsharp, { scratch: "s" });
  assert.equal(run.command, "dotnet");
  assert.deepEqual(run.args.slice(0, 5), ["test", "--filter-query", "/*/*/*/lawLaw1_*", "--filter-query", "/*/*/*/lawLaw1"]);
  assert.ok(run.args.includes("--report-xunit-junit"));
  assert.deepEqual(await ranLaws({ language: "fsharp" }, fsharp,
    '<testsuites><testsuite><testcase name="example.unit::law 1 property" classname="LawSpec.Tests.ExampleUnit"/>' +
    '<testcase name="example.unit::law 10 example 0: first" classname="LawSpec.Tests.ExampleUnit"/></testsuite></testsuites>'), [1, 10]);
  assert.deepEqual(await ranLaws({ language: "csharp" }, [law(1, "tests/LawSpec/ExampleUnit.cs", undefined, "csharp")],
    '<testsuites><testsuite><testcase name="example.unit::law 10 property" classname="LawSpec.Tests.ExampleUnit"/></testsuite></testsuites>'), []);
  assert.deepEqual(await ranLaws({ language: "fsharp" }, fsharp,
    '<testsuites><testsuite><testcase name="example.unit::law 1 boundary 256 — values.lawspec:9(caseIndex: 256)" classname="LawSpec.Tests.ExampleUnit"/>' +
    '<testcase name="example.unit::law 10 boundary 1(caseIndex: 1)" classname="LawSpec.Tests.ExampleUnit"/>' +
    '<testcase name="example.unit::law 1 boundary fake" classname="LawSpec.Tests.ExampleUnit"/></testsuite></testsuites>'), [1, 10]);
  const coverage = invocations({ language: "csharp" }, [law(1, "tests/LawSpec/ExampleUnit.cs")], { coverage: "c" });
  assert.ok(coverage[0].args.includes("--coverage"));
  const bench = benchmarkInvocations({ language: "fsharp" }, [{ unit: "example.unit", benchmark: "a booking", file: "tests/LawSpec/ExampleUnit.fs", name: "benchmarkABooking" }]);
  assert.deepEqual(bench[0].args, ["test", "--filter-query", "/*/*/*/benchmarkABooking"]);
});

test('native model slots use exact selectors and never accept a similarly prefixed completion',()=>{
  const slots=[
    ['python','tests/test_example_actors_lawspec.py','test_model_account',undefined],
    ['javascript','test/example_actors.lawspec.test.mjs','example.actors::model account',undefined],
    ['typescript','test/example_actors.lawspec.test.ts','example.actors::model account',undefined],
    ['go','example/actors/lawspec_models_test.go','TestModelAccount',undefined],
    ['java','src/test/java/example/ActorsModelTest.java','modelAccount','example.ActorsModelTest'],
    ['kotlin','src/test/kotlin/example/ActorsModelTest.kt','example.actors::model account','example.ActorsModelTest'],
    ['scala','src/test/scala/example/ActorsModelTest.scala','example.actors::model account','example.ActorsModelTest'],
    ['groovy','src/test/groovy/example/ActorsModelSpec.groovy','model account','example.ActorsModelSpec'],
    ['clojure','test/example/actors_model_test.clj','model-account','example.actors-model-test'],
    ['haskell','test/Example/ActorsModelSpec.hs','model account','Example.ActorsModel'],
    ['rust','tests/example_actors_lawspec.rs','model_account',undefined],
  ];
  for(const [language,file,name,scope] of slots){
    const entry={...law(0,file,'example.actors::model account'),unit:'example.actors',
      law:'example.actors::model::account::sequential',name,kind:'model',...(scope?{scope}:{})};
    const runs=invocations({language},[entry],{scratch:'.scratch'});
    const run=runs.find(run=>run.laws?.length);
    assert.ok(run,language);
    const completion={name,classname:scope??'',status:'passed'};
    if(language==='typescript'||language==='javascript')completion.name=entry.label;
    assert.deepEqual(run.ran(completion),[entry],language);
    assert.deepEqual(run.ran({...completion,name:completion.name+'_extra'}),[],language+' prefix');
    if(scope)assert.deepEqual(run.ran({...completion,classname:'foreign.scope'}),[],language+' scope');
    if(language==='python'){
      assert.ok(run.args.includes(file+'::'+name));assert.ok(!run.args.includes('-k'));
    }
    if(language==='clojure')assert.ok(run.args.includes('--select-exact'));
    if(language==='scala')assert.ok(run.args.includes('-t'));
    if(language==='haskell')assert.ok(run.args.at(-1).includes('"/Example.ActorsModel/example.actors models/model account/"'));
  }
});

test('a grouped native model completion covers its included checks without scheduling duplicate methods',()=>{
  const base={...law(0,'src/test/java/example/ActorsModelTest.java','example.actors::model account'),
    unit:'example.actors',name:'modelAccount',kind:'model',scope:'example.ActorsModelTest'};
  const entries=['sequential','parallel',`scenario::receipt
`].map(role=>({...base,law:'example.actors::model::account::'+role}));
  const [run]=invocations({language:'java'},entries);
  assert.equal(run.args.find(arg=>arg.startsWith('-Dtest=')),'-Dtest=example.ActorsModelTest#modelAccount');
  assert.deepEqual(run.ran({name:'modelAccount',classname:'example.ActorsModelTest',status:'passed'}),entries);
  assert.deepEqual(run.ran({name:'modelAccount_other',classname:'example.ActorsModelTest',status:'passed'}),[]);
});

test('Hspec model completions retain their complete names and discovered module scope',async()=>{
  const output='Example.ActorsModel\n  example.actors models\n    model account [✔]\n    supervision [✔]\n    model other [✘]\n\nFinished in 0.01 seconds\n3 examples, 1 failure\n';
  const completed=await executedTests({kind:'hspec'},output,'.',0);
  assert.deepEqual(completed,[
    {name:'model account',classname:'Example.ActorsModel',status:'passed'},
    {name:'supervision',classname:'Example.ActorsModel',status:'passed'},
    {name:'model other',classname:'Example.ActorsModel',status:'failed'},
  ]);
});

test('completion matching identifies failed native checks without counting them as passed',()=>{
  for(const language of ['javascript','typescript','erlang','elixir','gleam']){
    const entry={...law(0,'test/example.lawspec.test.mjs','example::model account'),
      unit:'example',law:'example::model::account::sequential',name:'model_account__sequential',kind:'model'};
    if(['javascript','typescript'].includes(language))entry.label='example::model account';
    const run=invocations({language},[entry]).find(run=>run.laws?.length);
    const completion={name:entry.label,identity:`${entry.unit}::${entry.name}`,status:'failed'};
    assert.deepEqual(run.matches(completion),[entry],language);
    assert.deepEqual(run.ran(completion),[],language);
  }
});

test('JUnit round trips structured incomplete execution without inferring status from error text',async()=>{
  const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-junit-incomplete-'));
  try {
    const file=path.join(root,'status.xml');
    await writeFile(file,junitFromTests([
      {name:'pending',classname:'native',status:'incomplete',failure:'search bound exhausted'},
      {name:'wrong',classname:'native',status:'failed',failure:'incomplete is just text'},
      {name:'complete',classname:'native',status:'passed'}]));
    const rows=await executedTests({kind:'junit',files:[file]},'',root,0);
    assert.deepEqual(rows.map(row=>row.status),['incomplete','failed','passed']);
    assert.match(rows[0].failure,/search bound exhausted/);
  } finally {await rm(root,{recursive:true,force:true});}
});

test('JUnit completions retain failures and reject stale explicit reports and fake CDATA cases',async()=>{
  const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-native-junit-'));
  try{
    const file=path.join(root,'report.xml');
    await writeFile(file,`<testsuite><testcase name='pass' classname='bank'/>
      <testcase name="bad" classname="bank"><failure message="wrong &lt;value&gt;"><![CDATA[actual 1; expected 2 <testcase name="fake"/>]]></failure></testcase>
      <testcase name="error"><error message="setup"/></testcase><testcase name="skip"><skipped message="disabled"/></testcase></testsuite>`);
    const rows=await executedTests({kind:'junit',files:[file]},'',root,0);
    assert.deepEqual(rows.map(row=>row.name),['pass','bad','error','skip']);
    assert.deepEqual(rows.map(row=>row.status),['passed','failed','failed','skipped']);
    assert.match(rows[1].failure,/wrong <value>/);assert.match(rows[1].failure,/actual 1; expected 2/);
    const {utimes}=await import('node:fs/promises');await utimes(file,new Date(0),new Date(0));
    assert.deepEqual(await executedTests({kind:'junit',files:[file]},'',root,Date.now()),[]);
  }finally{await rm(root,{recursive:true,force:true});}
});


test('Haskell prepares Stack-owned build metadata before hashing an execution',()=>{
  assert.deepEqual(configurationInvocations({language:'haskell'}),[
    {command:'stack',args:['--no-terminal','config','build-files']}]);
  assert.deepEqual(configurationInvocations({language:'javascript'}),[]);
});


test("recording inputs affect externally observing laws while checked ordinary laws stay current",()=>{
  const input={build:"compiler",target:{language:"javascript"},machineBits:64,environment:"node",project:"project",
    tests:[{law:"recording",key:"same",callsAdapters:true},{law:"pure",key:"same",callsAdapters:false}]};
  const before=lawKeys({...input,recorded:"first"}),after=lawKeys({...input,recorded:"second"});
  assert.notEqual(before.get("recording"),after.get("recording"));
  assert.equal(before.get("pure"),after.get("pure"));
});
