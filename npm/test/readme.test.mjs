import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { createCompiler } from "../api.mjs";
test("every README LawSpec snippet compiles with required expectations", async () => {
  const readme = await readFile(
    new URL("../../README.md", import.meta.url),
    "utf8",
  );
  const compiler = await createCompiler();
  const blocks = [...readme.matchAll(/```lawspec\n([\s\S]*?)```/g)];
  assert.ok(blocks.length >= 5);
  for (const [i, match] of blocks.entries()) {
    let content = match[1];
    if (!content.startsWith("unit "))
      content =
        "unit migration\nitoa :: Int32 -> Text\natoi :: Text -> Int32\nlaw `round trip` is definition is `left inverse` atoi itoa end\n" +
        content +
        "\nend";
    const result = await compiler.check({
      sources: [{ path: `README-example-${i}.lawspec`, content }],
    });
    assert.deepEqual(result.diagnostics, []);
    assert.ok(
      result.laws
        .flatMap((l) => l.original.examples)
        .every((ex) => ex.expectations.length > 0),
    );
  }
});
