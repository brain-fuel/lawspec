import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile, mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import { createCompiler } from "../api.mjs";
const compiler = await createCompiler();
const sources = await Promise.all(
  ["algebra", "currying"].map(async (n) => ({
    path: n + ".lawspec",
    content: await readFile(
      new URL(`../../examples/specs/${n}.lawspec`, import.meta.url),
      "utf8",
    ),
  })),
);
const count = (a) =>
  a.kind === "equal"
    ? 1
    : a.kind === "implies"
      ? count(a.body)
      : a.items.reduce((n, a) => n + count(a), 0);

test("all algebra laws expand, including both sides and four division equations", async () => {
  const r = await compiler.expand({ sources });
  assert.deepEqual(r.diagnostics, []);
  assert.equal(r.laws.length, 22);
  const expectedLaws = [
    "commutative",
    "associative",
    "left identity",
    "right identity",
    "identity",
    "left absorbing element",
    "right absorbing element",
    "absorbing element",
    "left distributive",
    "right distributive",
    "distributive",
    "idempotent operation",
    "left inverse element",
    "right inverse element",
    "invertible",
    "left division",
    "right division",
    "divisible",
    "involution",
  ];
  assert.deepEqual(
    r.laws
      .filter((l) => l.owner === "example.algebra")
      .map((l) => expectedLaws.find(n => l.trace[1] === n || l.trace[1].startsWith(n + " ")))
      .sort(),
    expectedLaws.sort(),
  );
  assert.ok(
    r.laws.every(
      (l) =>
        l.examples.length > 0 &&
        l.examples.every((e) => e.expectations.length > 0),
    ),
  );

  const byName = Object.fromEntries(r.laws.map((l) => [l.name, l]));
  assert.equal(count(byName["subtraction has divisible"].assertion), 4);
  for (const name of [
    "zero is two-sided identity for addition",
    "zero absorbs multiplication on both sides",
    "multiplication distributes over addition on both sides",
    "negation supplies both additive inverses",
    "subtraction has left division",
    "subtraction has right division",
  ])
    assert.equal(count(byName[name].assertion), 2, name);
  assert.match(
    r.expansions.at(-1),
    /format \("port:"\) \(true\) \(443\) \(trim \(x\)\)/,
  );
  for (const target of [
    "java",
    "python",
    "javascript",
    "typescript",
    "go",
    "haskell",
    "kotlin",
  ]) {
    const plan = await compiler.planGeneration({ sources, target });
    assert.deepEqual(plan.diagnostics, [], target);
    assert.equal(plan.files.filter(f => f.ownership === "user").length, 2);
    assert.equal(plan.files.filter(f => f.placement === "test").length, 2);
  }
});

test("currying has no fixed arity cap and rejects incomplete or mistyped applications", async () => {
  const types = Array(13).fill("Int32").join(" -> ");
  const args = Array.from({ length: 11 }, (_, i) => String(i)).join(" ");
  const content = `unit arity\nf :: ${types}\nlaw \`twelve\` is definition is \`equivalent\` (f ${args}) (f ${args}) end example \`last input\` is x = 12 expect f ${args} x = 67 end end`;
  const check = (content) =>
    compiler.check({ sources: [{ path: "arity.lawspec", content }] });
  assert.deepEqual((await check(content)).diagnostics, []);
  for (const target of [
    "java",
    "python",
    "javascript",
    "typescript",
    "go",
    "haskell",
    "kotlin",
  ]) {
    const plan = await compiler.planGeneration({
      sources: [{ path: "arity.lawspec", content }],
      target,
    });
    assert.deepEqual(plan.diagnostics, []);
    if (target !== "haskell") assert.match(plan.files[0].content, /value11/);
  }
  for (const bad of [
    content.replace("Int32 -> Int32", "Bool -> Int32"),
    content.replace(`expect f ${args} x = 67`, `expect f ${args} = 67`),
    content.replace(`expect f ${args} x = 67`, `expect f ${args} x x = 67`),
  ])
    assert.ok((await check(bad)).diagnostics.length);
});

test("conjunction evaluates shared guards once and checks later conjuncts independently", async () => {
  const root = await mkdtemp(path.join(process.cwd(), ".lawspec-algebra-"));
  const exec = promisify(execFile);
  const env = { ...process.env };
  delete env.NODE_TEST_CONTEXT;
  const source = `unit compound
predicate :: Int32 -> Bool
operation :: Int32 -> Int32 -> Int32
law \`shared guard\` is definition is
 \`for all\` (x :: Int32) . predicate x implies (operation 0 x = x and operation x 0 = x)
end example \`right side matters\` is x = 3 expect x = 3 end end`;
  const run = () =>
    exec(
      process.execPath,
      [
        "--test",
        "--test-name-pattern",
        "example: right side matters",
        "test/compound.lawspec.test.mjs",
      ],
      { cwd: root, env },
    );
  const good = `let calls=0; export function predicate(x){calls++;return true;} export function operation(x,y){return x+y;} process.on('exit',()=>console.log('GUARDS='+calls));`;
  async function generate(content) {
    const r = await compiler.planGeneration({
      sources: [{ path: "compound.lawspec", content }],
      target: "javascript",
    });
    assert.deepEqual(r.diagnostics, []);
    for (const f of r.files) {
      const dest = path.join(root, f.path);
      await mkdir(path.dirname(dest), { recursive: true });
      if (f.ownership === "generated") await writeFile(dest, f.content);
    }
  }
  try {
    await generate(source);
    await mkdir(path.join(root, "node_modules/fast-check"), {
      recursive: true,
    });
    await writeFile(
      path.join(root, "node_modules/fast-check/package.json"),
      JSON.stringify({ type: "module", exports: "./index.js" }),
    );
    await writeFile(
      path.join(root, "node_modules/fast-check/index.js"),
      "export default {integer:()=>null,property:()=>null,assert:()=>{}};",
    );
    const adapter = path.join(root, "src/compound.mjs");
    await writeFile(adapter, good);
    assert.match((await run()).stdout, /GUARDS=1\s/);
    await writeFile(adapter, good.replace("return x+y;", "return y;"));
    await assert.rejects(run(), (e) => /AssertionError/.test(e.stdout));
    await writeFile(
      adapter,
      good
        .replace("return true;", "return false;")
        .replace("return x+y;", "throw Error('consequence evaluated');"),
    );
    assert.match((await run()).stdout, /GUARDS=1\s/);
    // Parentheses restrict the guard to the first conjunct; the second still runs.
    await generate(
      source.replace(
        "predicate x implies (operation 0 x = x and operation x 0 = x)",
        "(predicate x implies operation 0 x = x) and operation x 0 = x",
      ),
    );
    await assert.rejects(run(), (e) => /consequence evaluated/.test(e.stdout));
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
