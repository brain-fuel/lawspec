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
  assert.equal(result.laws[0].inputs[0].inputName, "x");
  assert.equal(
    result.expansions[0],
    "for all (x :: Int32) . atoi (itoa (x)) = x",
  );
});
test("all seven backends return deterministic owned artifact plans", async () => {
  for (const target of [
    "java",
    "python",
    "javascript",
    "typescript",
    "go",
    "haskell",
    "kotlin",
  ]) {
    const request = { ...input, target };
    const [a, b] = await Promise.all([
      compiler.planGeneration(request),
      compiler.planGeneration(request),
    ]);
    assert.deepEqual(a, b);
    assert.deepEqual(a.diagnostics, []);
    assert.deepEqual(
      a.files.map((f) => f.ownership),
      ["user", "generated"],
    );
    assert.match(a.files[1].content, /2147483647/);
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
    assert.match(result.files[1].content, /λ 日本語 😀/);
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
  ]) {
    const result = await compiler.planGeneration({ ...request, target });
    assert.deepEqual(result.diagnostics, []);
    assert.deepEqual(
      result.files.map((f) => f.ownership),
      ["user", "generated"],
    );
    assert.match(result.files[1].content, /decimal renderers agree/);
    assert.match(result.files[1].content, /nonnegative clamps agree/);
  }
});
