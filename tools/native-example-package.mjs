// Check exported native projects through the installed package, outside the checkout.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir,readFile,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
const root=path.resolve(import.meta.dirname,'..');
const directory=path.join(root,'.artifacts/native-example-package');
await mkdir(directory,{recursive:true});
const env={...process.env,npm_config_cache:path.join(root,'.artifacts/npm-cache'),
  CARGO_NET_OFFLINE:'true',CARGO_TARGET_DIR:path.join(directory,'cargo-target')};
const run=(command,args,cwd)=>execFileSync(command,args,{cwd,env,encoding:'utf8',maxBuffer:32*1024*1024});
const packed=JSON.parse(run('npm',['pack','--json','--pack-destination',directory],path.join(root,'npm')))[0];
const installation=path.join(directory,'installation');
await rm(installation,{recursive:true,force:true});
await mkdir(installation,{recursive:true});
run('npm',['install','--offline','--ignore-scripts','--no-audit','--no-fund','--prefix',installation,
  path.join(directory,packed.filename)],directory);
const cli=path.join(installation,'node_modules/lawspec/bin/lawspec.mjs');
const workspace=path.join(directory,'workspace');
await rm(workspace,{recursive:true,force:true});
await mkdir(workspace,{recursive:true});
const projects=JSON.parse(run(process.execPath,[cli,'examples','--example','payments','--json'],workspace));
assert.equal(projects.length,8);
for(const project of projects){
  run(process.execPath,[cli,'check'],project.directory);
  const config=JSON.parse(await readFile(path.join(project.directory,'lawspec.json'),'utf8'));
  assert.equal(config.targets[0].language,project.target);
  assert.ok(config.targets[0].nativeBindings.generators.length);
}
console.log('Installed CLI: all eight native payment projects export and pass check');
const rust=projects.find(project=>project.target==='rust');
run(process.execPath,[cli,'generate'],rust.directory);
const tests=run('cargo',['test','--offline','--quiet'],rust.directory);
assert.match(tests,/test result: ok/);
await writeFile(path.join(directory,'rust-tests.log'),tests);
const before=await readFile(path.join(rust.directory,'.lawspec/generated.json'),'utf8');
const repeated=JSON.parse(run(process.execPath,[cli,'examples','--example','payments','--target','rust','--json'],workspace));
assert.equal(repeated[0].changes,0);
assert.equal(await readFile(path.join(rust.directory,'.lawspec/generated.json'),'utf8'),before);
run(process.execPath,[cli,'generate','--check'],rust.directory);
console.log('Installed Rust project: generate, cargo test, re-export, and generation check pass');
