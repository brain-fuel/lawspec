import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile, mkdtemp, mkdir, writeFile, rm } from "node:fs/promises";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import { createCompiler } from "../api.mjs";
const compiler = await createCompiler();
const check = (content) =>
  compiler.expand({ sources: [{ path: "predicates.lawspec", content }] });

test("port predicates, reusable guards and Bool literals survive the public API", async () => {
  const content = await readFile(
    new URL("../../examples/specs/parse_port.lawspec", import.meta.url),
    "utf8",
  );
  const result = await check(content);
  assert.deepEqual(result.diagnostics, []);
  assert.equal(result.laws.length, 2);
  for (const law of result.laws) {
    assert.equal(law.guards.length, 1);
    assert.equal(law.guards[0].contents[0].contents, "validPort");
    assert.equal(law.guards[0].contents[1].contents, law.inputs[0].inputId);
  }
  assert.match(
    result.expansions[0],
    /validPort \(x\) implies parse \(render \(x\)\) = x/,
  );
  assert.deepEqual(
    result.laws[0].original.examples[0].expectations[0].expected,
    {type:"Bool",value:true},
  );
  assert.deepEqual(
    result.laws[0].original.examples[3].expectations[0].expected,
    {type:"Bool",value:false},
  );
  for (const bad of [
    content.replace(
      "validPort :: Int32 -> Bool",
      "validPort :: Int32 -> Int32",
    ),
    content.replace("validPort x implies", "missing x implies"),
    content.replace("expect validPort x = true", "expect validPort x = 1"),
    content.replace("x = 443", "x = true"),
    content.replaceAll("validPort", "implies"),
    content.replaceAll("validPort", "true"),
    content.replaceAll("validPort", "false"),
  ])
    assert.ok((await check(bad)).diagnostics.length);
});

test("Bool equality, predicate laws, nested conditions and generic wrappers type-check", async () => {
  for (const definition of [
    "`satisfies` f",
    "`equivalent` f f",
    "`for all` (x :: Bool) . f x",
    "`for all` (x :: Bool) . x implies f x implies true",
    "`for all` (x :: Bool) . true implies f x = false",
  ])
    assert.deepEqual(
      (
        await check(
          `unit flags\nf :: Bool -> Bool\nlaw \`check\` is definition is ${definition} end example \`false flag\` is x = false expect f x = true end end`,
        )
      ).diagnostics,
      [],
    );
  const nested = await check(
    "unit nested\np :: Int32 -> Bool\nf :: Int32 -> Int32\nlaw `guarded` (p :: a -> Bool) (f :: a -> a) requires Eq a is definition is `for all` (x :: a) . p x implies p (f x) implies f x = x end end\nlaw `use` is definition is `guarded` p f end end",
  );
  assert.deepEqual(nested.diagnostics, []);
  assert.equal(nested.laws[0].guards.length, 2);
  assert.match(nested.expansions[0], /p \(x\) implies p \(f \(x\)\) implies/);
});

test("generated implications short-circuit in order, evaluate once, and keep expectations unconditional", async () => {
  const root = await mkdtemp(path.join(process.cwd(), ".lawspec-predicates-"));
  const exec = promisify(execFile);
  const env = { ...process.env };
  delete env.NODE_TEST_CONTEXT;
  const source = `unit conditions
first :: Int32 -> Bool
second :: Int32 -> Bool
result :: Int32 -> Int32
law \`guarded\` is
 definition is \`for all\` (x :: Int32) . first x implies second x implies result x = x end
 example \`outer false\` is x = -1 expect first x = false end
 example \`inner false\` is x = 10 expect second x = false end
 example \`both true\` is x = 3 expect result x = 3 end
end`;
  async function generate(content) {
    const r = await compiler.planGeneration({
      target: "javascript",
      sources: [{ path: "conditions.lawspec", content }],
    });
    assert.deepEqual(r.diagnostics, []);
    for (const f of r.files) {
      const file = path.join(root, f.path);
      await mkdir(path.dirname(file), { recursive: true });
      if (f.ownership === "generated") await writeFile(file, f.content);
    }
  }
  const adapter = `let calls=[];
export function first(x){calls.push('first'); return x>0;}
export function second(x){calls.push('second'); if(x<=0)throw Error('second evaluated outside domain'); return x<10;}
export function result(x){calls.push('result'); if(x<=0||x>=10)throw Error('result evaluated outside domain'); return x;}
process.on('exit',()=>console.log('CALLS='+calls.join(',')));`;
  const run = (name) =>
    exec(
      process.execPath,
      [
        "--test",
        "--test-name-pattern",
        `example: ${name}`,
        "test/conditions.lawspec.test.mjs",
      ],
      { cwd: root, env },
    );
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
    await writeFile(path.join(root, "src/conditions.mjs"), adapter);
    assert.match((await run("outer false")).stdout, /CALLS=first,first\s/);
    assert.match(
      (await run("inner false")).stdout,
      /CALLS=second,first,second\s/,
    );
    assert.match(
      (await run("both true")).stdout,
      /CALLS=result,first,second,result\s/,
    );
    await generate(
      source.replace("expect first x = false", "expect result x = -1"),
    );
    await assert.rejects(run("outer false"), (e) =>
      /result evaluated outside domain/.test(e.stdout),
    );
    await generate(source);
    await writeFile(
      path.join(root, "src/conditions.mjs"),
      adapter.replace("return x>0;", "throw Error('predicate failed');"),
    );
    await assert.rejects(run("both true"), (e) =>
      /predicate failed/.test(e.stdout),
    );
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
