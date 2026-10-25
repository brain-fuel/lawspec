// Generated from templates/npm/input-files.mjs by lawspec-dev generate. Do not edit.
// Native implementations may depend on declared files outside their target
// directory. Component descriptions and native result keys share this walker.
import {createHash} from 'node:crypto';
import {lstat,readFile,readdir} from 'node:fs/promises';
import path from 'node:path';

export const buildDirectories = new Set(['.git','.lawspec','node_modules','dist','build','target','out','.gradle','bin','obj','TestResults',
  '.stack-work','_build','deps','.elixir_ls','__pycache__','.hypothesis','.pytest_cache','.venv','venv','.idea','.vscode',
  '.scala-build','.bsp','.bloop','.metals','.build','.swiftpm','.cpcache']);

// These outputs belong to the generated crypto builder; its sources and
// other priv/ assets still contribute to the native implementation identity.
export const cryptoBuildOutput = file => /(?:^|\/)priv\/lawspec_crypto_native\.(?:so|dll)(?:\.build|\.\d+\.tmp)?$/.test(file);

// Execution reports are observations, independent of implementation inputs.
// ref:DEC-completed-run-attestation
export function isAttestation(content) {
  try {
    const value = JSON.parse(content);
    return value !== null && typeof value === 'object' && value.format === 'environment-attestation';
  } catch { return false; }
}

export async function fingerprintInputs(root,inputs,{generated=new Set()}={}) {
  if(!Array.isArray(inputs)||inputs.some(entry=>typeof entry!=='string'||!entry))
    throw new Error('Component inputs must be an array of nonempty paths');
  const rows = new Map();
  async function visit(file,relative) {
    const info = await lstat(file);
    if(info.isSymbolicLink())throw new Error(`Symbolic links are not supported in component inputs: ${relative}`);
    if(info.isDirectory()) {
      for(const entry of (await readdir(file)).sort()) {
        if(buildDirectories.has(entry))continue;
        const next=relative+'/'+entry;
        if(next.endsWith('testdata/rapid'))continue;
        await visit(path.join(file,entry),next);
      }
    } else if(info.isFile()&&!generated.has(path.resolve(file))&&!cryptoBuildOutput(relative)) {
      const content=await readFile(file);
      if(relative.endsWith('.json')&&isAttestation(content.toString('utf8')))return;
      rows.set(relative,createHash('sha256').update(content).digest('hex'));
    }
  }
  for(const entry of inputs)await visit(path.resolve(root,entry),entry.split(path.sep).join('/'));
  return [...rows].sort(([left],[right])=>left<right?-1:left>right?1:0);
}
