import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createCompiler } from "../api.mjs";
const content = await readFile(
  new URL("../starter.lawspec", import.meta.url),
  "utf8",
);
const input = { sources: [{ path: "codec.lawspec", content }] };
const compiler = await createCompiler();
test("WASM expands the scratch law and preserves inherited example inputs", async () => {
  const result = await compiler.expand(input);
  assert.deepEqual(result.diagnostics, []);
  assert.equal(result.laws[0].inputs[0].name, "x");
  assert.equal(
    result.expansions[0],
    "for all (x :: Int32) . atoi (itoa (x)) = x",
  );
});
test("all eight backends return deterministic owned artifact plans", async () => {
  for (const target of [
    "java",
    "python",
    "javascript",
    "typescript",
    "go",
    "haskell",
    "kotlin",
    "rust",
  ]) {
    const request = { ...input, target };
    const [a, b] = await Promise.all([
      compiler.planGeneration(request),
      compiler.planGeneration(request),
    ]);
    assert.deepEqual(a, b);
    assert.deepEqual(a.diagnostics, []);
    assert.deepEqual(
      a.files.filter(f => f.ownership === "user").map(f => f.placement),
      ["source"],
    );
    assert.match(a.files.find(f => f.placement === "test").content, /2147483647/);
  }
});
test("Unicode metadata survives repeated JSON/JSFFI calls", async () => {
  const request = {
    sources: [
      {
        path: "λ.lawspec",
        content: content.replace(
          "representing an Int32",
          "λ 日本語 😀 representing an Int32",
        ),
      },
    ],
  };
  for (let i = 0; i < 3; i++) {
    const result = await compiler.planGeneration({
      ...request,
      target: "python",
    });
    assert.deepEqual(result.diagnostics, []);
    assert.match(result.files.find(f => f.placement === "test").content, /λ 日本語 😀/);
  }
});
test("invalid examples, types and source syntax return structured diagnostics", async () => {
  for (const bad of [
    content.replace("x = -42", "y = -42"),
    content.replace("x = -42", "x = 2147483648"),
    content.replace("Int32 -> Text", "Bool -> Text"),
    content + "unexpected",
  ]) {
    const result = await compiler.check({
      sources: [{ path: "bad.lawspec", content: bad }],
    });
    assert.ok(result.diagnostics.length);
    assert.equal(typeof result.diagnostics[0].message, "string");
  }
});

test("equivalent specializes both result types on every backend", async () => {
  const content = await readFile(
    new URL("../../examples/specs/equivalent.lawspec", import.meta.url),
    "utf8",
  );
  const request = { sources: [{ path: "equivalent.lawspec", content }] };
  const expanded = await compiler.expand(request);
  assert.deepEqual(expanded.diagnostics, []);
  assert.deepEqual(expanded.expansions, [
    "for all (x :: Int32) . render (x) = referenceRender (x)",
    "for all (x :: Int32) . clamp (x) = referenceClamp (x)",
  ]);
  for (const target of [
    "java",
    "python",
    "javascript",
    "typescript",
    "go",
    "haskell",
    "kotlin",
    "rust",
  ]) {
    const result = await compiler.planGeneration({ ...request, target });
    assert.deepEqual(result.diagnostics, []);
    assert.deepEqual(
      result.files.filter(f => f.ownership === "user").map(f => f.placement),
      ["source"],
    );
    assert.match(result.files.find(f => f.placement === "test").content, /decimal renderers agree/);
    assert.match(result.files.find(f => f.placement === "test").content, /nonnegative clamps agree/);
  }
});

test("Text laws, idempotence, escaped examples and mixed inputs work on every backend", async () => {
  const sources = await Promise.all(
    ["slug", "canonical_url", "mixed_inputs"].map(async (name) => ({
      path: `${name}.lawspec`,
      content: await readFile(
        new URL(`../../examples/specs/${name}.lawspec`, import.meta.url),
        "utf8",
      ),
    })),
  );
  const result = await compiler.expand({ sources });
  assert.deepEqual(result.diagnostics, []);
  assert.equal(result.laws.length, 5);
  assert.match(result.expansions[0], /\(x :: Text\)/);
  assert.match(
    result.expansions[1],
    /canonicalize \(canonicalize \(x\)\) = canonicalize \(x\)/,
  );
  assert.deepEqual(
    result.laws[2].inputs.map((i) => i.type.name),
    ["Text", "Int32"],
  );
  assert.deepEqual(
    result.laws[0].examples[0].bindings[0].value,
    {type:"Text",units:[..."Hello, World!"].map(c=>c.codePointAt(0))},
  );
  for (const target of ['java','python','javascript','typescript','go','haskell','kotlin','rust']) {
    const plan = await compiler.planGeneration({ sources, target });
    assert.deepEqual(plan.diagnostics, []);
    assert.equal(plan.files.filter(f => f.ownership === 'user').length, 3);
    const tests = plan.files.filter(f => f.placement === 'test' && !f.path.includes('support/'));
    assert.equal(tests.length, 3);
    assert.ok(tests.every(f => f.content.includes('example')));
    assert.ok(plan.files.some(f => f.ownership === 'generated' && f.placement === 'source'));
  }
  for (const content of [
    sources[0].content.replace('x = "Hello, World!"', "x = 42"),
    sources[0].content.replace('x = "Hello, World!"', 'y = "oops"'),
    "unit bad\nf :: Text -> Int32\nlaw `bad` is definition is `idempotent` f end end",
  ]) {
    const invalid = await compiler.check({
      sources: [{ path: "bad.lawspec", content }],
    });
    assert.ok(invalid.diagnostics.length);
  }
});

test("examples require typed expectations and preserve multiple assertions in the API", async () => {
  const source = `unit example.expected
actual :: Int32 -> Text
law \`formats\` is
 definition is \`equivalent\` actual actual end
 example \`negative rendering\` is
  x = -42
  expect actual x = "-42"
  expect actual (x) = "-42"
 end
end`;
  const check = (content) =>
    compiler.check({ sources: [{ path: "expect.lawspec", content }] });
  const result = await check(source);
  assert.deepEqual(result.diagnostics, []);
  const assertions = result.laws[0].examples[0].expectations;
  assert.equal(assertions.length, 2);
  assert.equal(assertions[0].left.node.kind, "call");
  assert.deepEqual(assertions[0].right.node.value, {type:"Text",units:[45,52,50]});
  const failures = [
    [
      source.replace(/\s*expect actual[^\n]*/g, ""),
      /requires at least one expect/,
    ],
    [
      source.replace('expect actual x = "-42"', "expect actual x = -42"),
      /type/,
    ],
    [source.replace("expect actual x", "expect missing x"), /unknown/],
    [
      source.replace('expect actual x = "-42"', "expect x = 2147483648"),
      /Int32/,
    ],
    [source.replace('expect actual x = "-42"', "expect actual x = x"), /parse/],
    [source.replace("actual ::", "expect ::"), /parse/],
  ];
  for (const [content, message] of failures) {
    const r = await check(content);
    assert.ok(r.diagnostics.length);
    assert.match(JSON.stringify(r.diagnostics), message);
  }
  for (const target of [
    "java",
    "python",
    "javascript",
    "typescript",
    "go",
    "haskell",
    "kotlin",
    "rust",
  ]) {
    const r = await compiler.planGeneration({
      sources: [{ path: "expect.lawspec", content: source }],
      target,
    });
    assert.deepEqual(r.diagnostics, []);
    assert.ok(r.files.find(f => f.placement === "test").content.includes("negative rendering"));
    assert.ok(r.files.find(f => f.placement === "test").content.includes("expect actual"));
  }
});
