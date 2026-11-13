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

// A tool is what it contains and reports, wherever it is installed: a key
// holds no path, so worktrees and machines with the same tools agree.
const identity=({binary,...observed})=>observed;

// The variables that change what these checks do: the Haskell runtime's and
// Hspec's options, Node's, Python's, the locale and time zone the programs
// under test read, colour selection, toolchain selection, and LawSpec's own
// settings. The rest of a shell's environment (its session, its working
// directory, Stack's paths into one worktree) does not, and hashing it
// would make every terminal and worktree a different context. The settings
// that only say where results are cached or how runs are coordinated are
// left out for the same reason.
const environmentNames=new Set(['GHCRTS','LANG','LANGUAGE','TZ','NO_COLOR','FORCE_COLOR','CI',
  'JAVA_HOME','JAVA_TOOL_OPTIONS','_JAVA_OPTIONS','RUSTUP_TOOLCHAIN','CARGO_BUILD_TARGET',
  'GOARCH','GOOS','GOFLAGS','STACK_YAML','RAPID_TEST_VERSION','RAPID_TEST_REPLACE']);
const environmentPrefixes=['LAWSPEC_','HSPEC_','NODE_','LC_','PYTHON'];
const coordination=name=>name==='LAWSPEC_DEV_CACHE'||name==='LAWSPEC_CACHE'||name.startsWith('LAWSPEC_CI_');
export function effectiveEnvironment(environment) {
  return Object.fromEntries(Object.entries(environment)
    .filter(([name])=>!coordination(name)&&
      (environmentNames.has(name)||environmentPrefixes.some(prefix=>name.startsWith(prefix))))
    .sort(([a],[b])=>a<b?-1:a>b?1:0));
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
  const {binary:_,...solver}=z3;
  return {node:identity(node),python:identity(python),stack:identity(stack),ghc:identity(ghc),z3:solver};
}

// The SDK tests use whichever of these they find, so each one's presence and
// version is part of their context. A tool that is present but does not
// answer is recorded as such.
const optionalTools=[['node',['--version']],['npm',['--version']],['python3',['--version']],['uv',['--version']],
  ['git',['--version']],['go',['version']],['cargo',['-V']],['rustc',['-Vv']],['java',['-version']],['mvn',['-v']],
  ['gradle',['--version']],['kotlin',['-version']],['kotlinc',['-version']],['scala',['version']],
  ['scala-cli',['version']],['clojure',['--version']],['groovy',['--version']],['coursier',['--version']],
  ['cs',['--version']],['dotnet',['--version']],['swift',['--version']],
  ['erl',['-noshell','-eval','io:format("~s~n", [erlang:system_info(system_version)]), halt().']],
  ['rebar3',['version']],['elixir',['--version']],['mix',['--version']],['gleam',['--version']],
  ['stack',['--version']],['ghc',['--numeric-version']],['swipl',['--version']],['z3',['-version']],
  ['tsc',['--version']],['cc',['--version']],['make',['--version']],['tofu',['version']]];
// Tools the tests take from the environment rather than from PATH.
const selectedTools=['LAWSPEC_Z3','LAWSPEC_TSC','LAWSPEC_GHC','LAWSPEC_PYTHON_EXECUTABLE'];
// What the bootstraps installed for the tests to use.
const integrationFiles=['javascript/package-lock.json','typescript/package-lock.json','scala/lawspec.edn',
  'gleam/manifest.toml','python/.venv/pyvenv.cfg','prolog/.venv/pyvenv.cfg'];

async function present(file) {
  try{return digest(await readFile(file));}
  catch(error){if(['ENOENT','ENOTDIR','EISDIR'].includes(error.code))return null;throw error;}
}

async function answer(binary,arguments_,root,environment) {
  try {
    const result=await exec(binary,arguments_,{cwd:root,env:environment,maxBuffer:4*1024*1024,timeout:60000});
    return result.stdout+result.stderr;
  } catch{return null;}
}

async function sdkTestContext(root,environment) {
  const tools=await Promise.all(optionalTools.map(async([command,arguments_])=>{
    const binary=await executable(command,root,environment,{optional:true});
    return [command,binary===null?{present:false}:{present:true,version:await answer(binary,arguments_,root,environment)}];
  }));
  const selected=await Promise.all(selectedTools.filter(name=>environment[name])
    .map(async name=>[name,await present(path.resolve(root,environment[name]))]));
  const integration=await Promise.all(integrationFiles.map(async file=>
    [file,await present(path.join(root,'.integration',file))]));
  const packages=await Promise.all(['python','prolog'].map(async target=>{
    const python=path.join(root,'.integration',target,'.venv/bin/python');
    return [target,await present(python)===null?null:await answer(python,['-m','pip','freeze','--all'],root,environment)];
  }));
  return {tools,selected,integration,packages};
}

export async function artifactKey(mode,{root=repository,environment=process.env,nativeCompiler}={}) {
  if(!['parity','compiler-tests','npm-tests'].includes(mode))throw new Error('This check has no certified reusable artifact context: '+mode);
  const sdk=path.join(root,'npm');
  // Hash the effective environment without printing its values. In
  // particular GHCRTS, HSPEC_OPTIONS and Node options affect these checks.
  const context={host:await fingerprintNativeHost(sdk),versions:process.versions,
    environment:effectiveEnvironment(environment)};
  const files=(await readdir(sdk)).filter(name=>name.endsWith('.mjs')||
    ['core_jsffi.js','core.wasm','package.json'].includes(name)).sort();
  const executableFiles=await Promise.all(files.map(async name=>[name,digest(await readFile(path.join(sdk,name)))]));
  const sdkDigest=digest(JSON.stringify(executableFiles));
  if(mode==='compiler-tests')return {format:'lawspec-compiler-tests-key-2',sdk:sdkDigest,
    context:digest(JSON.stringify(context)),tools:digest(JSON.stringify(await compilerTestTools(root,environment)))};
  if(mode==='npm-tests')return {format:'lawspec-npm-tests-key-1',sdk:sdkDigest,
    context:digest(JSON.stringify(context)),tools:digest(JSON.stringify(await sdkTestContext(root,environment)))};
  const binary=nativeCompiler??environment.LAWSPEC_CORE??path.join(
    (await exec('stack',['path','--local-install-root'],{cwd:root,env:environment})).stdout.trim(),
    'bin/lawspec-core');
  return {format:'lawspec-parity-key-2',native:digest(await readFile(binary)),
    sdk:sdkDigest,context:digest(JSON.stringify(context))};
}

if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))
  console.log(JSON.stringify(await artifactKey(process.argv[2])));
