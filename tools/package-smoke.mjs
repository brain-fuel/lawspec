// Generated from templates/tools/package-smoke.mjs by lawspec-dev generate. Do not edit.
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, mkdir, readFile, writeFile, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { targets } from "../npm/templates.mjs";
const exec = promisify(execFile);
const repo = path.resolve(import.meta.dirname, "..");
const output = process.env.LAWSPEC_PACKAGE_DIR ??
  path.join(repo, ".artifacts/package-smoke");
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
async function run(cmd, args, cwd = root, {timeout = 1800000} = {}) {
  const started = Date.now();
  console.log(`[package-smoke] ${JSON.stringify([cmd, ...args])}`);
  try {
    const result = await exec(cmd, args, {
      cwd,
      encoding: "utf8",
      maxBuffer: 4 * 1024 * 1024,
      timeout,
    });
    console.log(`[package-smoke] completed in ${(Date.now() - started) / 1000}s`);
    return result;
  } catch (e) {
    throw new Error(
      `${JSON.stringify([cmd, ...args])} failed after ${(Date.now() - started) / 1000}s ` +
      `(code=${e.code}, signal=${e.signal}, killed=${e.killed}): ${e.stdout}\n${e.stderr}`,
      {cause: e},
    );
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
  // Init deliberately selects no optional law checks. This smoke run opts in
  // before exercising the generated native tests.
  const configPath = path.join(app, "lawspec.json");
  const config = JSON.parse(await readFile(configPath, "utf8"));
  if (config.version !== 2 || config.languageProfile !== "1.0-rc.1" ||
      config.verification.layers.length !== 0)
    throw new Error("Init did not create the canonical profile with no selected checks");
  config.verification = {layers: ["property", "examples"]};
  await writeFile(configPath, JSON.stringify(config, null, 2) + "\n");
  await run("npm", ["exec", "--no", "--", "lawspec", "check"], app);
  const explanation = await run(
    "npm",
    [
      "exec",
      "--no",
      "--",
      "lawspec",
      "explain",
      "example.codec::codec",
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
    path.join(app, "src/example/codec.mjs"),
    "export const itoa = String;\nexport const atoi = Number;\n",
  );
  await run("npm", ["test"], app);
  await run(process.execPath, [cli, "generate", "--check"], app);
  // Exporting the expanded corpus, including the portable Unicode tables,
  // reached the old thirty-minute guard. Retain every export and assertion
  // while allowing an hour for this operation; other commands keep their limit.
  await run("npm", ["exec", "--no", "--", "lawspec", "examples"], app,
    {timeout: 3600000});
  const textTest = await readFile(
    path.join(
      app,
      "example_artifacts/java/src/test/java/example/SlugLawSpecTest.java",
    ),
    "utf8",
  );
  if (
    !textTest.includes('LawSpecRuntime.sample("Text"') || !textTest.includes("PropertyChecker")
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
    !portTest.includes("if (") || !portTest.includes("ParsePort.validPort(") ||
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
       const legacy=sources=>c.migrationBaseline({schemaVersion:5,languageProfile:'1.0-rc.1',
         verification:{layers:[]},from:'0.24',sources});
       const source=readFileSync(new URL('./examples/specs/equivalent.lawspec', import.meta.resolve('lawspec')), 'utf8');
       const rejected=await c.expand({schemaVersion:3,sources:[{path:'equivalent.lawspec',content:source}]});
       if(rejected.schemaVersion!==5 || !rejected.diagnostics.length)throw new Error('Installed API silently accepted schema 3');
       const r=await legacy([{path:'equivalent.lawspec',content:source}]);
       if(r.schemaVersion!==5 || r.sourceLanguageProfile!=='0.24' || r.diagnostics.length || r.laws.length!==2 || !r.expansions[0].includes('referenceRender'))throw new Error(JSON.stringify(r));
       const port=readFileSync(new URL('./examples/specs/parse_port.lawspec', import.meta.resolve('lawspec')), 'utf8');
       const guarded=await legacy([{path:'parse_port.lawspec',content:port}]);
       if(guarded.diagnostics.length || guarded.laws[0].assertion.kind!=='implies' || !guarded.expansions[0].includes('implies'))throw new Error(JSON.stringify(guarded));
       const algebra=readFileSync(new URL('./examples/specs/algebra.lawspec', import.meta.resolve('lawspec')), 'utf8');
       const expanded=await legacy([{path:'algebra.lawspec',content:algebra}]);
       if(expanded.diagnostics.length || expanded.laws.length!==19 || !expanded.expansions.some(s=>s.includes('divideRight') && s.includes('divideLeft')))throw new Error(JSON.stringify(expanded));
       console.log('Installed API expands equivalent, predicate and all algebra examples');`,
    ],
    app,
  );
  console.log(api.stdout.trim());
  const structures = await run(process.execPath, ['--input-type=module', '-e', `
    import assert from 'node:assert/strict';
    import {readFileSync} from 'node:fs';
    import {createCompiler} from 'lawspec';
    const compiler = await createCompiler();
    const canonical=await compiler.check({schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]},
      sources:[{path:'starter.lawspec',content:readFileSync(new URL('./starter-rc1.lawspec',import.meta.resolve('lawspec')),'utf8')}]});
    assert.equal(canonical.schemaVersion,5);
    assert.deepEqual(canonical.diagnostics,[]);
    assert.ok(canonical.laws.length>0);
    const legacy=input=>compiler.migrationBaseline({schemaVersion:5,languageProfile:'1.0-rc.1',
      verification:{layers:[]},...input,from:'0.24'});
    const names = ['collections', 'data_types', 'total_functions',
      'recursive_refinements'];
    const sources = names.map(name => ({path: name + '.lawspec',
      content: readFileSync(new URL('./examples/specs/' + name + '.lawspec',
        import.meta.resolve('lawspec')), 'utf8')}));
    for (const machineBits of [32, 64]) {
      const checked = await legacy({sources, machineBits});
      assert.deepEqual(checked.diagnostics, []);
      assert.ok(checked.dataTypes.some(type => type.name === 'Tree'));
      assert.ok(checked.definitions.length > 0);
      for (const target of ${JSON.stringify(targets)}) {
        for (const minify of [false, true]) {
          const result = await legacy({sources, machineBits,
            target, minify,includeGeneration:true});
          assert.deepEqual(result.diagnostics, [], target);
          assert.ok(result.files.some(file => file.placement === 'source' &&
            file.ownership === 'generated'), target);
          assert.ok(result.files.some(file => file.placement === 'test'), target);
          assert.ok(result.files.every(file => file.content.length > 0), target);
        }
      }
    }
    console.log('Installed structural API: all ${targets.length} targets, widths and layouts');
  `], app);
  console.log(structures.stdout.trim());
  for (const document of [
                           "README.md",
                           "CHANGELOG.md",
                           "LICENSE",
                           "UNICODE-LICENSE.txt"
                         ])
    if (!(await readFile(path.join(app,'node_modules/lawspec',document),'utf8')).length) throw new Error('Missing packaged '+document);
  const rust=path.join(root,'rust');
  await mkdir(rust);
  await run(process.execPath,[cli,'init','--target','rust'],rust);
  const rustConfigPath = path.join(rust, 'lawspec.json');
  const rustConfig = JSON.parse(await readFile(rustConfigPath, 'utf8'));
  rustConfig.verification = {layers: ['property', 'examples']};
  await writeFile(rustConfigPath, JSON.stringify(rustConfig, null, 2) + '\n');
  await run(process.execPath,[cli,'doctor'],rust);
  await run(process.execPath,[cli,'generate'],rust);
  await writeFile(path.join(rust,'src/example/codec.rs'),'pub fn itoa(value:i32)->String {value.to_string()}\npub fn atoi(value:String)->i32 {value.parse().unwrap()}\n');
  await run('cargo',['test'],rust);
  await run(process.execPath,[cli,'generate','--check'],rust);
  console.log('Installed Rust scaffold, doctor, adapters, tests and regeneration passed');
  console.log(`Packed npm CLI/API smoke test passed: ${archive}`);
} finally {
  await rm(root, { recursive: true, force: true });
}
