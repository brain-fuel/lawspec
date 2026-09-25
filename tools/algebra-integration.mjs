// Exact algebra, including explicit overflow expectations and wrapping mutants.
import {execFileSync,spawn} from 'node:child_process';
import {readFile,mkdir,writeFile,symlink,copyFile,rm,access} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';
import {templates,targets} from '../npm/templates.mjs';
import {algebraAdapters} from './algebra-fixtures.mjs';
const root=path.resolve(import.meta.dirname,'..');
const bin=process.env.LAWSPEC_NATIVE==='1'?path.join(execFileSync('stack',['path','--local-install-root'],{cwd:root,encoding:'utf8'}).trim(),'bin/lawspec-core'):null;
const compiler=bin?null:await createCompiler();
const sources=await Promise.all(['algebra','currying'].map(async n=>({path:n+'.lawspec',content:await readFile(path.join(root,'examples/specs',n+'.lawspec'),'utf8')})));
const gradle=await access(path.join(root,'.tools/gradle-9.3.0/bin/gradle')).then(()=>path.join(root,'.tools/gradle-9.3.0/bin/gradle'),()=> 'gradle');
for(const target of process.argv.slice(2).length?process.argv.slice(2):targets){
 const dir=path.join(root,'.artifacts/algebra',target);await mkdir(dir,{recursive:true});
 for(const folder of ['src','test','tests','example'])await rm(path.join(dir,folder),{recursive:true,force:true});
 const input={sources,target};
 const result=bin?JSON.parse(execFileSync(bin,[],{input:JSON.stringify({method:'planGeneration',...input}),encoding:'utf8',maxBuffer:64*1024*1024})):await compiler.planGeneration(input);
 if(result.diagnostics.length)throw new Error(JSON.stringify(result.diagnostics));
 const adapters=algebraAdapters(target);
 for(const f of [...Object.entries(templates(target)).map(([path,content])=>({path,content})),...result.files]){
  const p=path.join(dir,f.path);await mkdir(path.dirname(p),{recursive:true});
  await writeFile(p,f.ownership==='user'?adapters.find(a=>a[0]===f.path)[1]:f.content);
 }
 if(['javascript','typescript'].includes(target))await symlink(path.join(root,'.integration',target,'node_modules'),path.join(dir,'node_modules')).catch(e=>{if(e.code!=='EEXIST')throw e});
 if(target==='go')await copyFile(path.join(root,'test/locks/go/go.sum'),path.join(dir,'go.sum'));
 const commands={rust:['cargo',['test',...(process.env.LAWSPEC_RUST_RELEASE==='1'?['--release']:[])]],java:['mvn',['-q','test']],python:[path.join(root,'.integration/python/.venv/bin/python'),['-B','-m','pytest','-q']],javascript:['node',['--test',...result.files.filter(f=>f.path.endsWith('.test.mjs')).map(f=>f.path)]],typescript:['npm',['test']],go:['go',['test','./...']],haskell:['stack',['--no-terminal','test']],kotlin:[gradle,['test','--console=plain']]};
 const [cmd,args]=commands[target];
 async function run(){return new Promise((resolve,reject)=>{const p=spawn(cmd,args,{cwd:dir});let log='';p.stdout.on('data',s=>log+=s);p.stderr.on('data',s=>log+=s);p.on('error',reject);p.on('exit',code=>resolve({code,log}));});}
 const good=await run();await writeFile(path.join(dir,'correct.log'),good.log);
 if(good.code)throw new Error(`${target}: correct algebra failed\n${good.log}`);
 console.log(`${target}: exact algebra and currying passed`);
 if(process.env.LAWSPEC_MUTANTS==='1')for(const [file,correct,...edits] of adapters){
  try {for(let i=0;i<edits.length;i+=2){
   if(!correct.includes(edits[i]))throw new Error(`missing mutant anchor: ${target}/${file}/${i}`);
   await writeFile(path.join(dir,file),correct.replace(edits[i],edits[i+1]));
   const report=await run();await writeFile(path.join(dir,`${path.basename(file)}-mutant-${i/2}.log`),report.log);
   if(!report.code||/error\[E\d+\]|could not compile|COMPILATION ERROR|compileTestKotlin FAILED|SyntaxError|\[build failed\]|parse error on input|not in scope/i.test(report.log))throw new Error(`${target}: algebra mutant ${i/2} escaped or failed to compile\n${report.log}`);
   console.log(`${target}: rejected ${file} mutant ${i/2}`);
  }}finally{await writeFile(path.join(dir,file),correct);}
 }
}
