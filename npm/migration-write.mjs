// Generated from templates/npm/migration-write.mjs by lawspec-dev generate. Do not edit.
// A write always obtains a fresh checked report. Serialized reports are review
// artifacts, never authorization to bypass the compiler's correspondence gates.
import {readFile,writeFile,open,link,rename,unlink,lstat,chmod} from 'node:fs/promises';
import path from 'node:path';
import {randomUUID} from 'node:crypto';
import {safePath,collectSources} from './files.mjs';
import {migrationReport} from './migrate.mjs';

const failure=(code,message,extra={})=>Object.assign(new Error(message),
  {diagnostics:[{code,message,at:null}],...extra});
const remove=async file=>{try{await unlink(file);}catch(error){if(error.code!=='ENOENT')throw error;}};
const unchanged=async entry=>{
  const info=await lstat(entry.file),bytes=await readFile(entry.file);
  if(!info.isFile()||info.dev!==entry.info.dev||info.ino!==entry.info.ino||info.mode!==entry.info.mode||
    !bytes.equals(Buffer.from(entry.expected,'utf8')))
    throw failure('migration-stale','File changed during migration: '+entry.path);
};

// Stage every replacement before committing, retain original inodes for
// rollback, and commit configuration last. A process/OS crash is not a global
// filesystem transaction; recovery paths are retained if rollback cannot finish.
export async function commitMigration(root,changes,{recheck=async()=>{},packageLocations=new Map()}={}){
  // Only manifest-observed package sources receive an alternate root. Ordinary
  // destinations retain the project's traversal and symbolic-link checks.
  const destination=relative=>{
    const location=packageLocations.get(relative);
    return location?safePath(location.root,location.path):safePath(root,relative);
  };
  const lockPath=await safePath(root,'.lawspec-migration.lock');
  let lock;
  try{lock=await open(lockPath,'wx');}
  catch(error){throw failure('migration-write',error.code==='EEXIST'?
    'A migration lock already exists: '+lockPath:error.message);}
  const entries=[],observed=[],applied=[],unrestored=[],recovery=[];
  let problem;
  try{
    if(new Set(changes.map(change=>change.path)).size!==changes.length)
      throw failure('migration-write','Duplicate migration destination.');
    for(const change of changes){
      if(typeof change.expected!=='string'||typeof change.content!=='string')
        throw failure('migration-write','Migration replacements require exact original and destination text.');
      const file=await destination(change.path),info=await lstat(file),bytes=await readFile(file);
      if(!info.isFile()||!(info.mode&0o222))throw failure('migration-write','Migration requires a writable regular file: '+change.path);
      if(!bytes.equals(Buffer.from(change.expected,'utf8')))
        throw failure('migration-stale','File changed during migration: '+change.path);
      observed.push({...change,file,info});
      if(change.expected===change.content)continue;
      const suffix='.lawspec-migrate-'+randomUUID();
      const entry={...change,file,info,stage:file+suffix+'.tmp',backup:file+suffix+'.bak'};
      entries.push(entry);
      await writeFile(entry.stage,entry.content,{flag:'wx',mode:info.mode&0o7777});
      await chmod(entry.stage,info.mode&0o7777);
      entry.stageInfo=await lstat(entry.stage);
      await link(file,entry.backup);
    }
    await recheck();
    for(const entry of observed){await destination(entry.path);await unchanged(entry);}
    for(const entry of entries){
      await destination(entry.path);await unchanged(entry);
      await rename(entry.stage,entry.file);applied.push(entry);
    }
  }catch(error){
    problem=error;
    for(const entry of applied.reverse()){
      try{
        // An editor's newer value must not be overwritten by rollback.
        const info=await lstat(entry.file);
        if(info.ino!==entry.stageInfo.ino||info.dev!==entry.stageInfo.dev||info.mode!==entry.stageInfo.mode||
          (await readFile(entry.file,'utf8'))!==entry.content)throw new Error('File changed after replacement.');
        await rename(entry.backup,entry.file);
      }catch(rollbackError){unrestored.push(entry.path);recovery.push({path:entry.path,original:entry.backup,reason:rollbackError.message});}
    }
  }finally{
    for(const entry of entries)for(const file of [entry.stage,entry.backup]){
      if(recovery.some(item=>item.original===file))continue;
      try{await remove(file);}catch(error){recovery.push({path:entry.path,original:file,reason:error.message});}
    }
    await lock.close();
    try{await remove(lockPath);}catch(error){recovery.push({path:'.lawspec-migration.lock',original:lockPath,reason:error.message});}
  }
  if(problem||recovery.length){
    const written=problem?unrestored:entries.map(entry=>entry.path);
    throw failure(problem?.diagnostics?.[0]?.code??'migration-write',
      (problem?.message??'Migration committed, but temporary-file cleanup is incomplete.')+
      (recovery.length?' Recovery files: '+recovery.map(item=>item.original).join(', '):''),
      {filesWritten:written,recovery});
  }
  return entries.map(entry=>entry.path);
}

export async function writeMigration(compiler,root,configurationPath,configurationText,input,{recheck}={}){
  const config=JSON.parse(configurationText),snapshot=structuredClone(input);
  if(config.version!==1||!Array.isArray(config.sources)||!Array.isArray(config.targets))
    throw failure('migration-configuration','Writing requires a version 1 configuration with sources and targets arrays.');
  const roots=config.targets.map(target=>typeof target?.root==='string'&&target.root&&!target.root.includes('\0')?
    path.resolve(root,target.root):null);
  if(roots.includes(null)||new Set(roots).size!==roots.length)
    throw failure('migration-configuration','Every configured target requires a distinct project root.');
  const packagePaths=config.packages??[],packages=snapshot.packages??[];
  if(!Array.isArray(packagePaths)||packagePaths.some(value=>typeof value!=='string')||
    !Array.isArray(packages)||packages.length!==packagePaths.length||snapshot.package!==undefined||
    JSON.stringify(snapshot.dependencies??{})!==JSON.stringify(config.dependencies??{}))
    throw failure('migration-configuration','Checked package inputs must match the project configuration.');
  if(snapshot.nativeBindings!==undefined)
    throw failure('migration-configuration','Project writing requires native bindings in configured targets, rather than one-off API bindings.');
  if((snapshot.machineBits??64)!==(config.machineBits??64)||
    JSON.stringify(snapshot.generation)!==JSON.stringify(config.generation))
    throw failure('migration-configuration','Project writing requires the machine width and generation settings from its configuration.');
  const packageLocations=new Map(),packageManifests=[];
  for(let index=0;index<packages.length;index++){
    const packageRoot=path.resolve(root,packagePaths[index]);
    const manifestPath=path.join(packageRoot,'lawspec-package.json');
    const text=await readFile(manifestPath,'utf8'),manifest=JSON.parse(text),pkg=packages[index];
    if(pkg.name!==manifest.name||pkg.version!==manifest.version||
      JSON.stringify(pkg.dependencies??{})!==JSON.stringify(manifest.dependencies??{})||
      JSON.stringify(pkg.sources)!==JSON.stringify(await collectSources(packageRoot,manifest.sources,root)))
      throw failure('migration-configuration','Checked package sources must match their configured manifest: '+packagePaths[index]);
    packageManifests.push({root:packageRoot,path:manifestPath,text,sources:manifest.sources,expected:pkg.sources});
    for(const source of pkg.sources){
      const relative=path.relative(packageRoot,path.resolve(root,source.path)).split(path.sep).join('/');
      await safePath(packageRoot,relative);
      if(packageLocations.has(source.path))throw failure('migration-configuration','Duplicate package source: '+source.path);
      packageLocations.set(source.path,{root:packageRoot,path:relative});
    }
  }
  const observeSources=async()=>{
    if(JSON.stringify(await collectSources(root,config.sources))!==JSON.stringify(snapshot.sources))
      throw failure('migration-stale','The complete project source inventory changed or differs from the checked input.');
    for(const pkg of packageManifests){
      if(await readFile(pkg.path,'utf8')!==pkg.text||
        JSON.stringify(await collectSources(pkg.root,pkg.sources,root))!==JSON.stringify(pkg.expected))
        throw failure('migration-stale','A package manifest or complete source inventory changed: '+pkg.path);
    }
  };
  if(['packages','package','dependencies'].some(key=>snapshot[key]!==undefined)&&typeof recheck!=='function')
    throw failure('migration-write','Package-backed migration requires rechecking package inputs before committing.');
  await observeSources();
  const report=await migrationReport(compiler,config,snapshot);
  if(report.diagnostics.length)throw Object.assign(new Error(report.diagnostics.map(item=>item.message).join(' ')),
    {diagnostics:report.diagnostics});
  if(!report.validated)throw failure('migration-incomplete',report.blockers.join(' ')||'Migration correspondence was not established.');
  const originalSources=[...snapshot.sources,...packages.flatMap(pkg=>pkg.sources)];
  const previewSources=[...report.sourcePreview.sources,...(report.sourcePreview.packages??[]).flatMap(pkg=>pkg.sources)];
  const originals=new Map(originalSources.map(source=>[source.path,source.content]));
  if(originals.size!==originalSources.length||previewSources.length!==originals.size||
    new Set(previewSources.map(source=>source.path)).size!==originals.size||
    previewSources.some(source=>!originals.has(source.path)))
    throw failure('migration-write','Every admitted source must have exactly one replacement.');
  const changes=previewSources.map(source=>({path:source.path,
    expected:originals.get(source.path),content:source.content}));
  changes.push({path:configurationPath,expected:configurationText,
    content:JSON.stringify(report.proposedConfiguration,null,2)+'\n'});
  report.filesWritten=await commitMigration(root,changes,{packageLocations,recheck:async()=>{await recheck?.();await observeSources();}});
  return report;
}
