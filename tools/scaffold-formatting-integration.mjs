import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import path from "node:path";
import { tmpdir } from "node:os";
import { fileURLToPath } from "node:url";
import { targets, templates } from "../npm/templates.mjs";

const cli = fileURLToPath(new URL("../npm/bin/lawspec.mjs", import.meta.url));
const temporary = await mkdtemp(path.join(tmpdir(), "lawspec-scaffolds-"));
const xmlTree = (text) =>
  JSON.parse(
    execFileSync(
      "python3",
      [
        "-c",
        `
import json, sys, xml.etree.ElementTree as E
def tree(e):
    return [e.tag, e.attrib, (e.text or '').strip(), [tree(c) for c in e]]
print(json.dumps(tree(E.fromstring(sys.stdin.read()))))
`,
      ],
      { input: text, encoding: "utf8" },
    ),
  );
for (const target of targets) {
  const readable = templates(target);
  const compact = templates(target, { minify: true });
  assert.deepEqual(templates(target, { minify: false }), readable);
  assert.deepEqual(Object.keys(compact), Object.keys(readable));
  for (const name of Object.keys(readable)) {
    if (name.endsWith(".json")) {
      assert.deepEqual(JSON.parse(readable[name]), JSON.parse(compact[name]));
      assert.ok(compact[name].length < readable[name].length);
    } else if (name.endsWith(".xml")) {
      assert.deepEqual(xmlTree(readable[name]), xmlTree(compact[name]));
      assert.ok(compact[name].length < readable[name].length);
      assert.match(readable[name], /<build>\n    <plugins>/);
    }
  }
  for (const minify of [false, true]) {
    const root = path.join(temporary, `${target}-${minify}`);
    await mkdir(root);
    const args = [
      cli,
      "init",
      "--target",
      target,
      ...(minify ? ["--minify"] : []),
    ];
    execFileSync(process.execPath, args, { cwd: root, encoding: "utf8" });
    const expected = minify ? compact : readable;
    for (const [name, content] of Object.entries(expected)) {
      assert.equal(await readFile(path.join(root, name), "utf8"), content);
    }
    const configText = await readFile(path.join(root, "lawspec.json"), "utf8");
    const config = JSON.parse(configText);
    assert.deepEqual(config, {
      version: 1,
      sources: ["laws"],
      targets: [{ language: target, root: "." }],
    });
    assert.equal(
      configText,
      JSON.stringify(config, null, minify ? undefined : 2) + "\n",
    );
    assert.ok(
      (
        await readFile(path.join(root, "laws/atoi_codec.lawspec"), "utf8")
      ).includes("unit "),
    );
    const existing = path.join(temporary, `${target}-${minify}-existing`);
    await mkdir(existing);
    const build = Object.keys(expected).find((name) => !name.includes("/"));
    assert.ok(build);
    const userContent = expected[build] + "\n";
    await writeFile(path.join(existing, build), userContent);
    const message = execFileSync(process.execPath, args, {
      cwd: existing,
      encoding: "utf8",
    });
    assert.match(message, /Existing build files preserved/);
    assert.equal(
      await readFile(path.join(existing, build), "utf8"),
      userContent,
    );
  }
  console.log(
    `${target}: readable/compact init, config and user-owned build preservation pass`,
  );
}
assert.throws(() => templates("java", { minify: "yes" }), /boolean/);
assert.match(templates("kotlin")["build.gradle.kts"], /plugins \{\n    kotlin/);
assert.ok(
  templates("kotlin", { minify: true })["build.gradle.kts"].length <
    templates("kotlin")["build.gradle.kts"].length,
);
console.log(`Scaffold fixtures: ${temporary}`);
const nested = path.join(temporary, "nested-project");
await mkdir(nested);
execFileSync(
  process.execPath,
  [
    cli,
    "init",
    "--target",
    "javascript",
    "--project",
    "applications/web",
    "--machine-bits",
    "32",
    "--minify",
  ],
  { cwd: nested, encoding: "utf8" },
);
assert.equal(
  await readFile(path.join(nested, "applications/web/package.json"), "utf8"),
  templates("javascript", { minify: true })["package.json"],
);
assert.deepEqual(
  JSON.parse(await readFile(path.join(nested, "lawspec.json"), "utf8")),
  {
    version: 1,
    sources: ["laws"],
    machineBits: 32,
    targets: [{ language: "javascript", root: "applications/web" }],
  },
);
console.log(
  "Nested project placement and machine profile survive compact initialization",
);
