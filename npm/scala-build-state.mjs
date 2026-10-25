// Generated from templates/npm/scala-build-state.mjs by lawspec-dev generate. Do not edit.
// Preserve failed compiler state before an adapter restore or another build
// changes it. These diagnostics are not completed native execution evidence.
import {mkdir,readFile,readdir,realpath,stat,writeFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import path from 'node:path';

export const isScalaCompilationFailure = output =>
  /error compiling project|compilation failed|unexpected error when (?:compiling|copying)/i.test(output);

export async function captureScalaBuildFailure({root,command,args,output,phase='native'}) {
  try {
    root=await realpath(root);
    if(!(await stat(root)).isDirectory())return null;
    const directory=path.join(root,'.lawspec','scala-build-failures',randomUUID());
    await mkdir(directory,{recursive:true});
    const inventory=[],configurations=[],errors=[];
    const build=path.join(root,'.scala-build');
    async function visit(folder) {
      const entries=await readdir(folder,{withFileTypes:true}).catch(error=>{
        if(error.code!=='ENOENT')errors.push({path:path.relative(root,folder),code:error.code});
        return [];
      });
      for(const entry of entries.sort((a,b)=>a.name.localeCompare(b.name))) {
        const file=path.join(folder,entry.name),relative=path.relative(root,file);
        // A symlink may point to another client's output or outside this
        // project. Record its presence without walking through it.
        if(entry.isSymbolicLink()){inventory.push({path:relative,kind:'symlink'});continue;}
        if(entry.isDirectory()){await visit(file);continue;}
        if(!entry.isFile())continue;
        if(/\.(?:class|tasty|betasty|sig)$/.test(entry.name)) {
          const info=await stat(file).catch(error=>{errors.push({path:relative,code:error.code});return null;});
          if(info)inventory.push({path:relative,bytes:info.size,modified:info.mtime.toISOString()});
        }
        if(path.basename(folder)==='.bloop'&&entry.name.endsWith('.json')) {
          const raw=await readFile(file,'utf8').catch(error=>{errors.push({path:relative,code:error.code});return null;});
          if(raw!==null) {
            await writeFile(path.join(directory,entry.name),raw);
            try {
              const {project}=JSON.parse(raw);
              configurations.push({file:relative,name:project?.name,directory:project?.directory,
                workspaceDir:project?.workspaceDir,classesDir:project?.classesDir,
                sources:project?.sources,dependencies:project?.dependencies,classpath:project?.classpath});
            }catch{errors.push({path:relative,code:'invalid-json'});}
          }
        }
      }
    }
    await visit(build);
    const lines=output.replace(/\x1b\[[0-9;]*m/g,'').split('\n');
    const first=lines.findIndex(line=>/\[error\]|error:/i.test(line));
    const state={version:1,capturedAt:new Date().toISOString(),root,phase,
      command,args,firstCompilerError:first<0?[]:lines.slice(Math.max(0,first-2),first+18),
      configurations,inventory,errors};
    await writeFile(path.join(directory,'state.json'),JSON.stringify(state,null,2)+'\n');
    await writeFile(path.join(directory,'compiler.log'),output);
    return directory;
  }catch{return null;} // Capture failure must never replace the compiler result.
}
