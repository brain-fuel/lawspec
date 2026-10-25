// Generated from templates/npm/test/cache.test.mjs by lawspec-dev generate. Do not edit.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import { mkdtemp, mkdir, readdir, readFile, writeFile, rm } from "node:fs/promises";
import path from "node:path";
import os from "node:os";
const exec = promisify(execFile);
const cli = new URL("../bin/lawspec.mjs", import.meta.url).pathname;
const spec = [
  "unit cache.example\n\n",
  "double :: Int32 -> Int32",
  `function twice (x :: Integer) -> Integer is x + x end function
`,
  `law twiceDoubles is definition: for all (x :: Integer) => twice x must be x * 2 end for all end definition end law
`,
  `law deterministic is definition: for all (x :: Int32) => double x must be double x end for all end definition end law
`,
  "end unit",
].join("\n") + "\n";
async function project(t, config = {}) {
  const root = await mkdtemp(path.join(os.tmpdir(), "lawspec-cache-"));
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(path.join(root, "laws"));
  await writeFile(path.join(root, "laws/example.lawspec"), spec);
  await writeFile(path.join(root, "lawspec.json"), JSON.stringify({
    version: 2, languageProfile: '1.0-rc.2', verification: {layers: []}, sources: ["laws"], targets: [{ language: "python", root: "." }], ...config,
  }));
  return root;
}
const check = (root, ...flags) => exec(process.execPath, [cli, "check", "--json", ...flags], { cwd: root })
  .then((result) => result.stdout);
async function entries(folder) {
  const found = [];
  for (const entry of await readdir(folder, { withFileTypes: true }))
    if (entry.isDirectory()) found.push(...await entries(path.join(folder, entry.name)));
    else found.push(path.join(folder, entry.name));
  return found;
}
test("check reuses work kept in .lawspec/cache, and recovers from a damaged entry", async (t) => {
  const root = await project(t);
  const first = await check(root);
  const cache = path.join(root, ".lawspec/cache");
  assert.equal(await readFile(path.join(cache, ".gitignore"), "utf8"), "*\n");
  const builds = (await readdir(cache)).filter((name) => name !== ".gitignore");
  assert.equal(builds.length, 1);
  const stored = await entries(path.join(cache, builds[0]));
  assert.ok(stored.length > 0);
  assert.equal(await check(root), first);
  await writeFile(stored[0], "damaged");
  assert.equal(await check(root), first);
  // Another compiler build's folder is removed.
  await mkdir(path.join(cache, "0000000000000000"));
  await check(root);
  assert.deepEqual((await readdir(cache)).sort(), [".gitignore", builds[0]].sort());
});
test("--no-cache and cache: false keep no cache", async (t) => {
  const flagged = await project(t);
  await check(flagged, "--no-cache");
  await assert.rejects(readdir(path.join(flagged, ".lawspec/cache")));
  const configured = await project(t, { cache: false });
  await check(configured);
  await assert.rejects(readdir(path.join(configured, ".lawspec/cache")));
  const invalid = await project(t, { cache: "yes" });
  await assert.rejects(check(invalid), (error) => /cache must be true or false/.test(error.stdout + error.stderr));
});


// SDK caches use the caller's actual host directories, including absolute
// paths, while the compiler sees only its dedicated WASI mount.
test("SDK cache roots are explicit mounts and concurrent root changes stay isolated",async t=>{
  const {createCompiler}=await import('../api.mjs');
  const roots=await Promise.all([0,1].map(()=>mkdtemp(path.join(os.tmpdir(),'lawspec-sdk-cache-'))));
  t.after(()=>Promise.all(roots.map(root=>rm(root,{recursive:true,force:true}))));
  const compiler=await createCompiler();
  const request=cacheDirectory=>({schemaVersion:5,languageProfile:'1.0-rc.2',cacheDirectory,
    verification:{layers:[]},sources:[{path:'input.lawspec',content:spec}]});
  const results=await Promise.all(roots.map(root=>compiler.check(request(root))));
  assert.deepEqual(results[0],results[1]);assert.deepEqual(results[0].diagnostics,[]);
  for(const root of roots){
    assert.ok((await entries(root)).length>0);
    const accidental=path.join(process.cwd(),root.replace(/^[/\\]+/,''));
    await assert.rejects(readdir(accidental),{code:'ENOENT'});
  }
  assert.deepEqual(await compiler.check(request(roots[0])),results[0]);
});

test("SDK persisted compiler memos are separated by the actual WASM binary",async t=>{
  const {copyFile,appendFile}=await import('node:fs/promises');
  const {createHash}=await import('node:crypto');
  const {fileURLToPath}=await import('node:url');
  const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-sdk-build-'));
  t.after(()=>rm(root,{recursive:true,force:true}));
  const cache=path.join(root,'cache'), variant=path.join(root,'variant');
  await mkdir(variant);
  for(const file of ['api.mjs','launcher.mjs','core_jsffi.js','core.wasm'])
    await copyFile(new URL('../'+file,import.meta.url),path.join(variant,file));
  await writeFile(path.join(variant,'package.json'),'{"type":"module"}\n');
  // A valid custom section changes the actual binary without changing its
  // compiler behavior. Both real builds must keep separate disk entries.
  const name=Buffer.from('lawspec-cache-test');
  const payload=Buffer.concat([Buffer.from([name.length]),name,Buffer.from([1])]);
  await appendFile(path.join(variant,'core.wasm'),Buffer.concat([Buffer.from([0,payload.length]),payload]));
  const input={schemaVersion:5,languageProfile:'1.0-rc.2',cacheDirectory:cache,verification:{layers:[]},sources:[{path:'input.lawspec',content:spec}]};
  const first=await import('../api.mjs');
  const expected=await (await first.createCompiler()).check(input);assert.deepEqual(expected.diagnostics,[]);
  const child=`import {createCompiler} from ${JSON.stringify(new URL('file://'+path.join(variant,'api.mjs')).href)};console.log(JSON.stringify(await(await createCompiler()).check(${JSON.stringify(input)})));`;
  const actual=JSON.parse((await exec(process.execPath,['--input-type=module','-e',child])).stdout);
  assert.deepEqual(actual,expected);
  const hash=async file=>createHash('sha256').update(await readFile(file)).digest('hex');
  const builds=[await hash(fileURLToPath(new URL('../core.wasm',import.meta.url))),await hash(path.join(variant,'core.wasm'))];
  assert.notEqual(builds[0],builds[1]);
  assert.deepEqual((await readdir(cache)).sort(),builds.sort());
  for(const build of builds)assert.ok((await entries(path.join(cache,build))).length>0);
});
