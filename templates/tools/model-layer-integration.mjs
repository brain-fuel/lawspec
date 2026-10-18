// Exercise independent law/model selection through the public CLI and native runners.
// ref:REQ-progressive-verification ref:DEC-stateful-models-linearizability
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {cp,mkdir,readFile,readdir,writeFile,rm,symlink} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const exec=promisify(execFile),repo=path.resolve(import.meta.dirname,'..');
const packageRoot=path.resolve(process.env.LAWSPEC_NPM_SOURCE??path.join(repo,'npm'));
const {templates,targets}=await import(pathToFileURL(path.join(packageRoot,'templates.mjs')));
const language=process.argv[2];assert.ok(targets.includes(language),'Pass a supported target');
const bits=Number(process.env.LAWSPEC_MACHINE_BITS??64),minify=process.env.LAWSPEC_MINIFY==='1';
assert.ok([32,64].includes(bits));
const base=path.join(repo,'.artifacts/model-layer-integration',`${language}-${bits}-${minify}`);
await rm(base,{recursive:true,force:true});await mkdir(base,{recursive:true});
const project=path.join(base,'project with spaces');await mkdir(project);
const cli=path.join(packageRoot,'bin/lawspec.mjs'),configPath=path.join(project,'lawspec.json');
const env={...process.env,PYTHONDONTWRITEBYTECODE:'1'};
if(env.LAWSPEC_OFFLINE==='1')Object.assign(env,{CARGO_NET_OFFLINE:'true',GOPROXY:'off',GOTOOLCHAIN:'local',HEX_OFFLINE:'1'});
let step=0;
async function run(command,args,{pass=true,environment={}}={}){
  console.log(`${language}: ${command} ${args.join(' ')}`);
  let result;try{result=await exec(command,args,{cwd:project,env:{...env,...environment},
    timeout:600000,maxBuffer:32*1024*1024});}catch(error){result=error;}
  const output=(result.stdout??'')+(result.stderr??'');
  await writeFile(path.join(base,`${String(++step).padStart(2,'0')}-${path.basename(command)}.log`),output);
  assert.ok(!result.killed&&!result.signal,output);
  if(pass)assert.equal(result.code??0,0,output);
  else assert.ok(Number.isInteger(result.code)&&result.code>0,`Expected native failure: ${output}`);
  return {stdout:result.stdout??'',output};
}
for(const [name,content]of Object.entries(templates(language,{minify}))){
  const destination=path.join(project,name);await mkdir(path.dirname(destination),{recursive:true});await writeFile(destination,content);
}
await cp(path.join(repo,'acceptance/actors',language,'files'),project,{recursive:true});
const target={language,root:'.'};
if(language==='python')target.python=process.env.LAWSPEC_PYTHON_EXECUTABLE??path.join(repo,'.integration/python/.venv/bin/python');
if(['javascript','typescript'].includes(language))await symlink(
  path.resolve(process.env.LAWSPEC_NODE_MODULES??path.join(repo,'.integration',language,'node_modules')),path.join(project,'node_modules'));
if(['kotlin','groovy'].includes(language))target.gradle=process.env.LAWSPEC_GRADLE??'gradle';
if(language==='scala')target.scala=process.env.LAWSPEC_SCALA??'scala';
if(language==='go')await run('go',['mod','download','pgregory.net/rapid']);
if(language==='haskell')await run('stack',['--no-terminal','build','--test','--only-dependencies']);
if(['erlang','elixir','gleam'].includes(language)){
  const lock={erlang:'rebar.lock',elixir:'mix.lock',gleam:'manifest.toml'}[language];
  await cp(path.join(repo,'test/locks',language,lock),path.join(project,lock));
  const dependencies=process.env.LAWSPEC_BEAM_DEPENDENCIES??path.join(repo,'.integration',language);
  const folders=language==='erlang'?['_build/test/lib/proper']:language==='elixir'?['deps/stream_data','_build/test/lib/stream_data']:['build/packages'];
  for(const folder of folders)if(existsSync(path.join(dependencies,folder))){
    await mkdir(path.dirname(path.join(project,folder)),{recursive:true});await cp(path.join(dependencies,folder),path.join(project,folder),{recursive:true});
  }
  if(language==='gleam')for(const entry of await readdir(path.join(dependencies,'build/packages'),{withFileTypes:true})){
    const folder=path.join('build/dev/erlang',entry.name);
    if(entry.isDirectory()&&existsSync(path.join(dependencies,folder))){
      await mkdir(path.dirname(path.join(project,folder)),{recursive:true});
      await cp(path.join(dependencies,folder),path.join(project,folder),{recursive:true});
    }
  }
}
const source=await readFile(path.join(repo,'test/fixtures/canonical-model-layer-selection.lawspec'),'utf8');
const before='Pair (n + amount) (n + amount)',after='Pair (n + 2 * amount) (n + 2 * amount)';
assert.equal(source.split(before).length,2);
const specification=path.join(project,'laws/actors.lawspec');await mkdir(path.dirname(specification),{recursive:true});
async function select(layers,content=source){
  await writeFile(configPath,JSON.stringify({version:2,languageProfile:'1.0-rc.1',machineBits:bits,
    verification:{layers},sources:['laws'],targets:[target]},null,2)+'\n');
  await writeFile(specification,content);
}
async function test(pass=true){
  await run(process.execPath,[cli,'generate',...(minify?['--minify']:[])]);
  const report=path.join(base,`native-${step}.xml`);
  const result=await run(process.execPath,[cli,'test','--fresh','--seed','811','--json',
    '--report',`junit=${report}`,...(minify?['--minify']:[])],{pass});
  if(!pass)assert.match(await readFile(report,'utf8'),/<failure\b/,'The mutant must fail a completed native test');
  const rows=JSON.parse(result.stdout);
  if(!Array.isArray(rows)){
    assert.equal(rows.testsExecuted,0);
    assert.equal(rows.verification.selection,'no-selected-checks');
    return rows;
  }
  assert.equal(rows.length,1);return rows[0];
}
// An incorrect reference transition is a valid total definition. It must not
// cause optional model execution when only the independent actor laws are selected.
await select(['property','examples'],source.replace(before,after));
const laws=await test();assert.ok(laws.ok,JSON.stringify(laws));assert.equal(laws.ran.length,2);
assert.ok(laws.ran.every(id=>!id.includes('::model::')&&!id.endsWith('::supervision')));
await select(['model']);
const models=await test();assert.ok(models.ok,JSON.stringify(models));assert.equal(models.ran.length,5);
assert.ok(models.ran.every(id=>id.includes('::model::')||id.endsWith('::supervision')));
await select(['model'],source.replace(before,after));
const failed=await test(false);assert.equal(failed.ok,false);
assert.ok(failed.ran.some(id=>id.includes('::model::account::')),JSON.stringify(failed));
await select([]);
const none=await test();assert.equal(none.testsExecuted,0);
await writeFile(path.join(base,'receipt.json'),JSON.stringify({language,bits,minify,laws,models,failed,none},null,2)+'\n');
console.log(`PASS ${language}: independent actor laws, five model checks, rejected reference mutant, no selected checks`);
