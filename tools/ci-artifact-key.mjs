// Generated from templates/tools/ci-artifact-key.mjs by lawspec-dev generate. Do not edit.
// Parity checks complete responses from the installed compiler artifacts.
// Source/artifact correspondence is validated by separate CI checks.
import {createHash} from 'node:crypto';
import {execFile} from 'node:child_process';
import {readFile,readdir} from 'node:fs/promises';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {promisify} from 'node:util';
import {fingerprintNativeHost} from '../npm/native-host.mjs';

const exec=promisify(execFile);
const repository=path.resolve(import.meta.dirname,'..');
const digest=value=>createHash('sha256').update(value).digest('hex');

export async function artifactKey(mode,{root=repository,environment=process.env,nativeCompiler}={}) {
  if(mode!=='parity')throw new Error('This check has no certified reusable artifact context: '+mode);
  const sdk=path.join(root,'npm');
  // Hash the full effective environment without printing its values. In
  // particular GHCRTS and Node options affect execution of these artifacts.
  const context={host:await fingerprintNativeHost(sdk),versions:process.versions,
    environment:Object.fromEntries(Object.entries(environment).sort(([a],[b])=>a<b?-1:a>b?1:0))};
  const binary=nativeCompiler??environment.LAWSPEC_CORE??path.join(
    (await exec('stack',['path','--local-install-root'],{cwd:root,env:environment})).stdout.trim(),
    'bin/lawspec-core');
  const files=(await readdir(sdk)).filter(name=>name.endsWith('.mjs')||
    ['core_jsffi.js','core.wasm','package.json'].includes(name)).sort();
  const executable=await Promise.all(files.map(async name=>[name,digest(await readFile(path.join(sdk,name)))]));
  return {format:'lawspec-parity-key-1',native:digest(await readFile(binary)),
    sdk:digest(JSON.stringify(executable)),context:digest(JSON.stringify(context))};
}

if(process.argv[1]&&path.resolve(process.argv[1])===fileURLToPath(import.meta.url))
  console.log(JSON.stringify(await artifactKey(process.argv[2])));
