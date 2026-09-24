// Runs generated tests against stubs, correct adapters, and deliberately broken adapters.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { readFile, writeFile, readdir, rm } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { equivalentAdapters } from "./equivalent-fixtures.mjs";
import { textAdapters, oracleMutants } from "./text-fixtures.mjs";
const exec = promisify(execFile);
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const cli = path.join(repo, "npm/bin/lawspec.mjs");
const implementations = {
  java: [
    "src/main/java/example/AtoiCodec.java",
    "package example;\npublic final class AtoiCodec { public static String itoa(int value) { return Integer.toString(value); } public static int atoi(String value) { return Integer.parseInt(value); } }\n",
    "Integer.parseInt(value)",
    "0",
  ],
  python: [
    "src/example/atoi_codec.py",
    "def itoa(value: int) -> str:\n    return str(value)\ndef atoi(value: str) -> int:\n    return int(value)\n",
    "int(value)",
    "0",
  ],
  javascript: [
    "src/example/atoi_codec.mjs",
    "export function itoa(value) { return String(value); }\nexport function atoi(value) { return Number(value); }\n",
    "Number(value)",
    "0",
  ],
  typescript: [
    "src/example/atoi_codec.ts",
    "export function itoa(value: number): string { return String(value); }\nexport function atoi(value: string): number { return Number(value); }\n",
    "Number(value)",
    "0",
  ],
  go: [
    "example/atoi_codec/adapter.go",
    'package atoi_codec\nimport "strconv"\nfunc Itoa(value int32) string { return strconv.FormatInt(int64(value),10) }\nfunc Atoi(value string) int32 { n,err := strconv.ParseInt(value,10,32); if err != nil { panic(err) }; return int32(n) }\n',
    "return int32(n)",
    "return int32(n) - int32(n)",
  ],
  haskell: [
    "src/Example/AtoiCodec.hs",
    "module Example.AtoiCodec where\nimport Data.Int (Int32)\nimport Data.Text (Text)\nimport qualified Data.Text as T\nitoa :: Int32 -> Text\nitoa = T.pack . show\natoi :: Text -> Int32\natoi = read . T.unpack\n",
    "read . T.unpack",
    "const 0",
  ],
  kotlin: [
    "src/main/kotlin/example/AtoiCodec.kt",
    "package example\nfun itoa(value: Int): String = value.toString()\nfun atoi(value: String): Int = value.toInt()\n",
    "value.toInt()",
    "0",
  ],
};
async function run(cmd, args, cwd, expectSuccess = true) {
  let result;
  try {
    result = await exec(cmd, args, {
      cwd,
      encoding: "utf8",
      maxBuffer: 8 * 1024 * 1024,
      timeout: 180000,
    });
  } catch (e) {
    if (!expectSuccess && typeof e.code === "number" && e.code > 0) return e;
    throw new Error(`${cmd} ${args.join(" ")}\n${e.stdout}\n${e.stderr}`);
  }
  if (!expectSuccess) throw new Error(`Expected ${cmd} to fail, but it passed`);
  return result;
}
async function runNodeTests(root, directory, extension, pass) {
  const files = (await readdir(path.join(root, directory)))
    .filter((f) => f.endsWith(extension))
    .sort();
  if (!files.length) throw new Error("No generated Node tests found");
  return run(
    "node",
    ["--test", ...files.map((f) => path.join(directory, f))],
    root,
    pass,
  );
}
async function testCommand(target, root, config, pass) {
  switch (target) {
    case "java":
      return run("mvn", ["-B", "-q", "test"], root, pass);
    case "python":
      // Same-size mutations within one second can reuse Python's timestamp-based
      // bytecode cache. Always load the freshly written fixture source.
      await rm(path.join(root, "src/example/__pycache__"), {
        recursive: true,
        force: true,
      });
      return run(
        config.targets[0].python || "python3",
        ["-B", "-m", "pytest", "-q"],
        root,
        pass,
      );
    case "javascript":
      return runNodeTests(root, "test", ".test.mjs", pass);
    case "typescript":
      await run("npm", ["exec", "--", "tsc", "-p", "tsconfig.json"], root);
      return runNodeTests(root, "dist/test", ".test.js", pass);
    case "go":
      return run("go", ["test", "./..."], root, pass);
    case "haskell":
      return run("stack", ["--no-terminal", "test"], root, pass);
    case "kotlin":
      return run(
        config.targets[0].gradle || "gradle",
        ["--no-daemon", "--console=plain", "test", "--rerun-tasks"],
        root,
        pass,
      );
  }
}
async function guardedGenerate(args, root) {
  const names = (await readdir(root)).filter(
    (n) =>
      /\.(?:json|toml|yaml|lock|cabal|kts)$/.test(n) ||
      ["go.mod", "go.sum"].includes(n),
  );
  const before = await Promise.all(
    names.map((n) => readFile(path.join(root, n), "utf8")),
  );
  await run("node", [cli, "generate", ...args], root);
  for (let i = 0; i < names.length; i++)
    if ((await readFile(path.join(root, names[i]), "utf8")) !== before[i])
      throw new Error(`Generation modified build file ${names[i]}`);
}
async function verify(target) {
  const root = path.join(repo, ".integration", target);
  const config = JSON.parse(
    await readFile(path.join(root, "lawspec.json"), "utf8"),
  );
  const [relative, good, was, mutant] = implementations[target];
  const specPath = path.join(root, "laws/atoi_codec.lawspec");
  const spec = await readFile(
    path.join(repo, "examples/specs/atoi_codec.lawspec"),
    "utf8",
  );
  if (!spec.includes("two independent inputs"))
    await writeFile(
      specPath,
      spec +
        "\nlaw `two independent inputs` is\n  definition is\n    `for all` (x :: Int32) (y :: Int32) . atoi (itoa x) = x\n  end\n  example `mixed` is\n    x = -42\n    y = 2147483647\n    expect atoi (itoa x) = -42\n  end\nend\n",
    );
  await writeFile(
    path.join(root, "laws/purelaw.lawspec"),
    "unit purelaw\nlaw `reflexivity $ λ` is definition is `for all` (x :: Int32) . x = x end end\n",
  );
  await writeFile(
    path.join(root, "laws/equivalent.lawspec"),
    await readFile(
      path.join(repo, "examples/specs/equivalent.lawspec"),
      "utf8",
    ),
  );
  for (const name of ["slug", "canonical_url", "mixed_inputs"]) {
    await writeFile(
      path.join(root, `laws/${name}.lawspec`),
      await readFile(path.join(repo, `examples/specs/${name}.lawspec`), "utf8"),
    );
  }
  await guardedGenerate([], root);
  const adapter = path.join(root, relative);
  const initial = await readFile(adapter, "utf8");
  if (initial.includes("TODO")) await testCommand(target, root, config, false);
  const [
    equivalentPath,
    equivalentGood,
    textWas,
    textMutant,
    intWas,
    intMutant,
  ] = equivalentAdapters[target];
  const equivalentAdapter = path.join(root, equivalentPath);
  const textFiles = textAdapters(target);
  for (const [file, content] of textFiles)
    await writeFile(path.join(root, file), content);
  await writeFile(equivalentAdapter, equivalentGood);
  await writeFile(adapter, good);
  try {
    await testCommand(target, root, config, true);
    await guardedGenerate(["--check"], root);
    if ((await readFile(adapter, "utf8")) !== good)
      throw new Error("User adapter changed");
    if ((await readFile(equivalentAdapter, "utf8")) !== equivalentGood)
      throw new Error("Equivalent adapter changed");
    for (const [before, after] of [
      [textWas, textMutant],
      [intWas, intMutant],
    ]) {
      await writeFile(equivalentAdapter, equivalentGood.replace(before, after));
      await testCommand(target, root, config, false);
    }
    await writeFile(equivalentAdapter, equivalentGood);
    for (const [file, content, before, after] of textFiles) {
      if ((await readFile(path.join(root, file), "utf8")) !== content)
        throw new Error("Text adapter changed");
      if (!before) continue;
      if (!content.includes(before))
        throw new Error("Missing text mutation marker");
      await writeFile(path.join(root, file), content.replace(before, after));
      await testCommand(target, root, config, false);
      await writeFile(path.join(root, file), content);
    }
    for (const [file, mutantSource, correct] of oracleMutants(target)) {
      await writeFile(path.join(root, file), mutantSource);
      const failure = await testCommand(target, root, config, false);
      let report = `${failure.stdout}\n${failure.stderr}`;
      if (target === "kotlin") {
        const reportDir = path.join(root, "build/test-results/test");
        for (const name of await readdir(reportDir))
          if (name.endsWith(".xml"))
            report += await readFile(path.join(reportDir, name), "utf8");
      }
      if (
        !report.includes("expect ") ||
        (!report.includes("Hello") &&
          !report.includes("https://example.com/path"))
      )
        throw new Error(
          `Missing expected-result diagnostics for ${target}: ${report}`,
        );
      await writeFile(path.join(root, file), correct);
    }
    await writeFile(adapter, good.replace(was, mutant));
    await testCommand(target, root, config, false);
  } finally {
    for (const [file, content] of textFiles)
      await writeFile(path.join(root, file), content);
    await writeFile(equivalentAdapter, equivalentGood);
    await writeFile(adapter, good);
  }
  console.log(
    `${target}: correct implementations pass; broken codec, alternatives, Text normalization and idempotence fail; regeneration preserves adapter`,
  );
}
const selected = process.argv.slice(2);
const results = await Promise.allSettled(
  (selected.length ? selected : Object.keys(implementations)).map(verify),
);
for (const r of results)
  if (r.status === "rejected") {
    console.error(r.reason);
    process.exitCode = 1;
  }
