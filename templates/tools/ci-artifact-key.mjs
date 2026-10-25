// CI validates compiler sources separately. Package and parity results depend
// on the executable artifacts they actually exercise, not unrelated fixtures.
import {createHash} from 'node:crypto';
import {execFile} from 'node:child_process';
import {mkdtemp,readFile,readdir,rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {promisify} from 'node:util';
import {fingerprintNativeHost} from '../npm/native-host.mjs';

const exec=promisify(execFile);
const repository=path.resolve(import.meta.dirname,'..');
const digest=value=>createHash('sha256').update(value).digest('hex');
const executionEnvironment=['NODE_OPTIONS','RUSTUP_TOOLCHAIN','RUSTUP_HOME','CARGO_HOME',
  'CARGO_TARGET_DIR','CARGO_BUILD_TARGET','RUSTFLAGS','CARGO_ENCODED_RUSTFLAGS',
  'RUSTC_WRAPPER','RUSTC_WORKSPACE_WRAPPER','RUSTC','RUSTDOC','RUSTDOCFLAGS'];

export async function artifactKey(mode,{root=repository,environment=process.env,
  nativeCompiler,probe=async command=>(await exec(command[0],command.slice(1),
    {cwd:root,env:environment,maxBuffer:8*1024*1024})).stdout}={}) {
  if(!['package-smoke','parity'].includes(mode))throw new Error('Unknown CI artifact check: '+mode);
  const sdk=path.join(root,'npm');
  const context={host:await fingerprintNativeHost(sdk),
    environment:Object.fromEntries((mode==='package-smoke'?executionEnvironment:['NODE_OPTIONS']).map(name=>[name,environment[name]??'']))};
  if(mode==='package-smoke') {
    context.tools=await Promise.all([['npm','--version'],['rustc','-Vv'],['cargo','-V']].map(probe));
    const temporary=await mkdtemp(path.join(os.tmpdir(),'lawspec-smoke-key-'));
    try {
      const {stdout}=await exec('npm',['pack','./npm','--json','--pack-destination',temporary],
        {cwd:root,env:environment,maxBuffer:8*1024*1024});
      const [packed]=JSON.parse(stdout);
      if(typeof packed?.integrity!=='string'||!packed.integrity.startsWith('sha512-'))
        throw new Error('npm pack did not identify the checked archive');
      return {format:'lawspec-package-smoke-key-1',archive:packed.integrity,
        context:digest(JSON.stringify(context))};
    } finally {await rm(temporary,{recursive:true,force:true});}
  }
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
