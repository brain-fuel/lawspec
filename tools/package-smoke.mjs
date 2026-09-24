import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, mkdir, readFile, writeFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
const exec = promisify(execFile);
const repo = path.resolve(import.meta.dirname, "..");
const output = path.join(repo, ".artifacts");
await mkdir(output, { recursive: true });
const packed = JSON.parse(
  (
    await exec(
      "npm",
      ["pack", "./npm", "--pack-destination", output, "--json"],
      { cwd: repo, encoding: "utf8" },
    )
  ).stdout,
);
const archive = path.join(output, packed[0].filename);
const root = await mkdtemp(path.join(os.tmpdir(), "lawspec-package-"));
async function run(cmd, args, cwd = root) {
  try {
    return await exec(cmd, args, {
      cwd,
      encoding: "utf8",
      maxBuffer: 4 * 1024 * 1024,
      timeout: 120000,
    });
  } catch (e) {
    throw new Error(`${cmd}: ${e.stdout}\n${e.stderr}`);
  }
}
try {
  const app = path.join(root, "app");
  await mkdir(app);
  // Follow the README quickstart using the exact release archive before publication.
  await run(
    "npm",
    [
      "exec",
      "--yes",
      `--package=${archive}`,
      "--",
      "lawspec",
      "init",
      "--target",
      "javascript",
    ],
    app,
  );
  await run(
    "npm",
    [
      "install",
      "--save-dev",
      "--ignore-scripts",
      "--no-audit",
      "--no-fund",
      archive,
    ],
    app,
  );
  const cli = path.join(app, "node_modules/lawspec/bin/lawspec.mjs");
  await run("npm", ["exec", "--no", "--", "lawspec", "check"], app);
  const explanation = await run(
    "npm",
    [
      "exec",
      "--no",
      "--",
      "lawspec",
      "explain",
      "example.atoi_codec::itoa and then atoi yields a",
    ],
    app,
  );
  if (
    !explanation.stdout.includes("expect itoa") ||
    !explanation.stdout.includes('"-42"')
  )
    throw new Error("explain omitted expected results");
  await run("npm", ["exec", "--no", "--", "lawspec", "doctor"], app);
  await run("npm", ["exec", "--no", "--", "lawspec", "generate"], app);
  await writeFile(
    path.join(app, "src/example/atoi_codec.mjs"),
    "export const itoa = String;\nexport const atoi = Number;\n",
  );
  await run("npm", ["test"], app);
  await run(process.execPath, [cli, "generate", "--check"], app);
  await run("npm", ["exec", "--no", "--", "lawspec", "examples"], app);
  const textTest = await readFile(
    path.join(
      app,
      "example_artifacts/java/src/test/java/example/SlugLawSpecTest.java",
    ),
    "utf8",
  );
  if (
    !textTest.includes("Generator.stringsOf(Generator.asciiPrintableChars())")
  )
    throw new Error("Installed examples command omitted Text generation");
  const portTest = await readFile(
    path.join(
      app,
      "example_artifacts/java/src/test/java/example/ParsePortLawSpecTest.java",
    ),
    "utf8",
  );
  if (
    !portTest.includes("if (ParsePort.validPort(") ||
    !portTest.includes("ordinary port")
  )
    throw new Error("Installed examples omitted predicate checks");
  const api = await run(
    process.execPath,
    [
      "--input-type=module",
      "-e",
      `import {createCompiler} from 'lawspec';
       import {readFileSync} from 'node:fs';
       const c=await createCompiler();
       const source=readFileSync(new URL('./examples/specs/equivalent.lawspec', import.meta.resolve('lawspec')), 'utf8');
       const r=await c.expand({sources:[{path:'equivalent.lawspec',content:source}]});
       if(r.diagnostics.length || r.laws.length!==2 || !r.expansions[0].includes('referenceRender'))throw new Error(JSON.stringify(r));
       const port=readFileSync(new URL('./examples/specs/parse_port.lawspec', import.meta.resolve('lawspec')), 'utf8');
       const guarded=await c.expand({sources:[{path:'parse_port.lawspec',content:port}]});
       if(guarded.diagnostics.length || guarded.laws[0].guards.length!==1 || !guarded.expansions[0].includes('implies'))throw new Error(JSON.stringify(guarded));
       console.log('Installed API expands equivalent and predicate examples');`,
    ],
    app,
  );
  console.log(api.stdout.trim());
  console.log(`Packed npm CLI/API smoke test passed: ${archive}`);
} finally {
  await rm(root, { recursive: true, force: true });
}
