// Generate and execute scalar examples on every installed native target.
import {execFileSync,spawn} from 'node:child_process';
import {readFile,mkdir,writeFile,symlink,copyFile,rm,access} from 'node:fs/promises';
import path from 'node:path';
import {implementScalarAdapter,scalarMutants} from './scalar-adapters.mjs';
import {createCompiler} from '../npm/api.mjs';
import {templates,targets} from '../npm/templates.mjs';
const root=path.resolve(import.meta.dirname,'..');
const bin=process.env.LAWSPEC_NATIVE === '1' ? path.join(execFileSync('stack',['path','--local-install-root'],{cwd:root,encoding:'utf8'}).trim(),'bin/lawspec-core') : null;
const compiler=bin ? null : await createCompiler();
const localGradle=path.join(root,'.tools/gradle-9.3.0/bin/gradle');
const gradle=await access(localGradle).then(()=>localGradle,()=> 'gradle');
const sources=await Promise.all(['scalars','scalar_adapters','scalar_catalog'].map(async name=>({path:name+'.lawspec',content:await readFile(path.join(root,'examples/specs',name+'.lawspec'),'utf8')})));
const vectors=JSON.parse(await readFile(path.join(root,'test/scalar-vectors.json'),'utf8'));
sources.push({path:'conformance.lawspec',content:'unit conformance\n'+vectors.map((v,i)=>`law \`vector ${i}\` is definition is \`for all\` (marker :: Unit) . ${v.expression} = ${v.expected} end end`).join('\n')});
const bits=Number(process.env.LAWSPEC_MACHINE_BITS || 64);
const mutants=process.env.LAWSPEC_MUTANTS === '1';
const selected=process.argv.slice(2).length?process.argv.slice(2):targets;
for(const target of selected){
 const dir=path.join(root,bits===64?'.artifacts/scalars':'.artifacts/scalars32',target);await mkdir(dir,{recursive:true});
 for(const folder of ['src','test','tests','example'])await rm(path.join(dir,folder),{recursive:true,force:true});
 const input={sources,target,machineBits:bits};
 const result=bin?JSON.parse(execFileSync(bin,[],{input:JSON.stringify({method:'planGeneration',...input}),encoding:'utf8',maxBuffer:64*1024*1024})):await compiler.planGeneration(input);
 if(result.diagnostics.length)throw new Error(JSON.stringify(result.diagnostics));
 for(const f of [...Object.entries(templates(target)).map(([path,content])=>({path,content})),...result.files]){
  const p=path.join(dir,f.path);await mkdir(path.dirname(p),{recursive:true});await writeFile(p,f.ownership==='user'&&/scalar_adapters|ScalarAdapters/.test(f.path)?implementScalarAdapter(target,f.content):f.content);
 }
 if(['javascript','typescript'].includes(target))await symlink(path.join(root,'.integration',target,'node_modules'),path.join(dir,'node_modules')).catch(e=>{if(e.code!=='EEXIST')throw e});
 if(target==='go')await copyFile(path.join(root,'test/locks/go/go.sum'),path.join(dir,'go.sum'));
 const commands={rust:['cargo',['test',...(process.env.LAWSPEC_RUST_RELEASE==='1'?['--release']:[])]],java:['mvn',['-q','test']],python:[path.join(root,'.integration/python/.venv/bin/python'),['-B','-m','pytest','-q']],javascript:['node',['--test',...result.files.filter(f=>f.path.endsWith('.test.mjs')).map(f=>f.path)]],typescript:['npm',['test']],go:['go',['test','./...']],haskell:['stack',['--no-terminal','test']],kotlin:[gradle,['test','--console=plain']]};
 const [cmd,args]=commands[target];
 const nativeBits=target==='rust'
  ? Number(execFileSync('rustc',['--print','cfg',...(process.env.CARGO_BUILD_TARGET?['--target',process.env.CARGO_BUILD_TARGET]:[])],{encoding:'utf8'}).match(/target_pointer_width="(32|64)"/)[1])
  : (target==='go'&&process.env.GOARCH==='386'?32:['arm64','x64'].includes(process.arch)?64:32);
 if(bits!==nativeBits&&['go','haskell','rust'].includes(target)){
  const report=await new Promise((resolve,reject)=>{const p=spawn(cmd,args,{cwd:dir});let log='';p.stdout.on('data',s=>log+=s);p.stderr.on('data',s=>log+=s);p.on('error',reject);p.on('exit',code=>resolve({code,log}));});
  await writeFile(path.join(dir,'architecture-mismatch.log'),report.log);
  if(!report.code||!report.log.includes('machineBits does not match native architecture'))throw new Error(target+': missing architecture mismatch diagnostic');
  console.log(`${target}: ${bits}-bit profile rejected for native ${nativeBits}-bit machine adapter`);
  continue;
 }
 await new Promise((resolve,reject)=>{const p=spawn(cmd,args,{cwd:dir,stdio:'inherit'});p.on('exit',code=>code?reject(new Error(`${target} exited ${code}`)):resolve());p.on('error',reject)});
 console.log(`${target}: scalar suite passed`);
 if(mutants){
  const artifact=result.files.find(f=>f.ownership==='user'&&/scalar_adapters|ScalarAdapters/.test(f.path));
  const adapter=path.join(dir,artifact.path),correct=await readFile(adapter,'utf8');
  try {
   for(const mutation of [{name:'stub',content:artifact.content},...scalarMutants(target,correct)]){
    await writeFile(adapter,mutation.content);
    const mutationArgs=target==='python'?[...args,'-x']:args;
    const report=await new Promise((resolve,reject)=>{const p=spawn(cmd,mutationArgs,{cwd:dir});let log='';p.stdout.on('data',s=>log+=s);p.stderr.on('data',s=>log+=s);p.on('error',reject);p.on('exit',code=>resolve({code,log}));});
    await writeFile(path.join(dir,`mutant-${mutation.name}.log`),report.log);
    if(!report.code)throw new Error(`${target}: mutant ${mutation.name} escaped detection`);
    if(/error\[E\d+\]|could not compile|COMPILATION ERROR|compileTestKotlin FAILED|SyntaxError|\[build failed\]|parse error on input|not in scope/i.test(report.log))throw new Error(`${target}: mutant ${mutation.name} failed to compile (see log)`);
    console.log(`${target}: rejected ${mutation.name}`);
   }
  } finally {await writeFile(adapter,correct);}
 }

}
