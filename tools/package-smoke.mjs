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
  await run("npm", [
    "install",
    "--ignore-scripts",
    "--no-audit",
    "--no-fund",
    archive,
  ]);
  const cli = path.join(root, "node_modules/lawspec/bin/lawspec.mjs");
  const app = path.join(root, "app");
  await mkdir(app);
  await run(process.execPath, [cli, "init", "--target", "javascript"], app);
  await run(
    "npm",
    ["install", "--ignore-scripts", "--no-audit", "--no-fund"],
    app,
  );
  await run(process.execPath, [cli, "check"], app);
  await run(process.execPath, [cli, "generate"], app);
  await writeFile(
    path.join(app, "src/example/atoi_codec.mjs"),
    "export const itoa = String;\nexport const atoi = Number;\n",
  );
  await run("npm", ["test"], app);
  await run(process.execPath, [cli, "generate", "--check"], app);
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
       console.log('Installed API expands the bundled equivalent examples');`,
    ],
    app,
  );
  console.log(api.stdout.trim());
  console.log(`Packed npm CLI/API smoke test passed: ${archive}`);
} finally {
  await rm(root, { recursive: true, force: true });
}
