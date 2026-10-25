// Bind reusable CI passes to the artifacts and external tools they execute.
// Source/artifact correspondence is validated by separate CI checks.
import {createHash} from 'node:crypto';
import {execFile} from 'node:child_process';
import {access,readFile,readdir,realpath,stat} from 'node:fs/promises';
import {constants} from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {promisify} from 'node:util';
import {fingerprintNativeHost} from '../npm/native-host.mjs';

const exec=promisify(execFile);
const repository=path.resolve(import.meta.dirname,'..');
const digest=value=>createHash('sha256').update(value).digest('hex');

async function executable(command,root,environment,{optional=false}={}) {
  if(typeof command!=='string'||!command)throw new Error('Empty compiler-test tool selection');
  const direct=path.isAbsolute(command)||command.includes('/')||(process.platform==='win32'&&command.includes('\\'));
  if(!direct&&typeof environment.PATH!=='string')throw new Error('Cannot identify compiler-test tools without PATH');
  const locations=direct?[path.resolve(root,command)]:environment.PATH.split(path.delimiter)
    .map(folder=>path.resolve(root,folder,command));
  const extensions=process.platform==='win32'&&!path.extname(command)?
    ['',...(environment.PATHEXT??'.COM;.EXE;.BAT;.CMD').split(';')]:[''];
  for(const location of locations)for(const extension of extensions){
    const candidate=location+extension;
    try {
      if(!(await stat(candidate)).isFile())continue;
      await access(candidate,constants.X_OK);
      return await realpath(candidate);
    } catch(error) {
      if(!['ENOENT','ENOTDIR'].includes(error.code))throw error;
    }
  }
  if(optional)return null;
  throw new Error('Required compiler-test executable is unavailable');
}

async function observe(binary,arguments_,root,environment) {
  try{return await exec(binary,arguments_,{cwd:root,env:environment,maxBuffer:4*1024*1024,timeout:30000});}
  catch{throw new Error('Compiler-test tool identity probe failed');}
}

async function tool(command,arguments_,root,environment) {
  const binary=await executable(command,root,environment);
  const result=await observe(binary,arguments_,root,environment);
  if(!(result.stdout+result.stderr).trim())throw new Error('Compiler-test tool identity probe was empty');
  return {binary,bytes:digest(await readFile(binary)),version:result.stdout+result.stderr};
}

async function compilerTestTools(root,environment) {
  const node=await tool('node',['--version'],root,environment);
  const python=await tool('python3',['--version'],root,environment);
  const stack=await tool('stack',['--version'],root,environment);
  const selected=(await observe(stack.binary,['path','--compiler-exe'],root,environment)).stdout.trim();
  if(!selected||selected.includes('\n')||selected.includes('\r'))throw new Error('Stack did not identify one selected GHC executable');
  const ghc=await tool(selected,['--numeric-version'],root,environment);
  // Match the Hspec gates exactly: an explicit (even empty) selection is not
  // optional. Only an absent implicit PATH lookup means pending integration.
  const explicit=environment.LAWSPEC_Z3!==undefined;
  const selectedZ3=explicit?environment.LAWSPEC_Z3:await executable('z3',root,environment,{optional:true});
  const z3=selectedZ3===null?{selection:'implicit-PATH',present:false}:
    {selection:explicit?'LAWSPEC_Z3':'implicit-PATH',present:true,...await tool(selectedZ3,['-version'],root,environment)};
  return {node,python,stack,ghc,z3};
}

export async function artifactKey(mode,{root=repository,environment=process.env,nativeCompiler}={}) {
  if(!['parity','compiler-tests'].includes(mode))throw new Error('This check has no certified reusable artifact context: '+mode);
  const sdk=path.join(root,'npm');
  // Hash the full effective environment without printing its values. In
  // particular GHCRTS, HSPEC_OPTIONS and Node options affect these checks.
  const context={host:await fingerprintNativeHost(sdk),versions:process.versions,
    environment:Object.fromEntries(Object.entries(environment).sort(([a],[b])=>a<b?-1:a>b?1:0))};
  const files=(await readdir(sdk)).filter(name=>name.endsWith('.mjs')||
    ['core_jsffi.js','core.wasm','package.json'].includes(name)).sort();
  const executableFiles=await Promise.all(files.map(async name=>[name,digest(await readFile(path.join(sdk,name)))]));
  const sdkDigest=digest(JSON.stringify(executableFiles));
  if(mode==='compiler-tests')return {format:'lawspec-compiler-tests-key-1',sdk:sdkDigest,
    context:digest(JSON.stringify(context)),tools:digest(JSON.stringify(await compilerTestTools(root,environment)))};
  const binary=nativeCompiler??environment.LAWSPEC_CORE??path.join(
    (await exec('stack',['path','--local-install-root'],{cwd:root,env:environment})).stdout.trim(),
    'bin/lawspec-core');
  return {format:'lawspec-parity-key-1',native:digest(await readFile(binary)),
    sdk:sdkDigest,context:digest(JSON.stringify(context))};
}

if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))
  console.log(JSON.stringify(await artifactKey(process.argv[2])));
