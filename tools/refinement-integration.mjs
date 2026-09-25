import {execFileSync,spawn} from 'node:child_process';
import {readFile,mkdir,writeFile,symlink,copyFile,rm,access} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';
import {templates,targets} from '../npm/templates.mjs';
const root=path.resolve(import.meta.dirname,'..');
const bin=process.env.LAWSPEC_NATIVE==='1'?path.join(execFileSync('stack',['path','--local-install-root'],{cwd:root,encoding:'utf8'}).trim(),'bin/lawspec-core'):null;
const compiler=bin?null:await createCompiler();
const bits=Number(process.env.LAWSPEC_MACHINE_BITS||64);
const sources=[{path:'refinements.lawspec',content:await readFile(path.join(root,'examples/specs/refinements.lawspec'),'utf8')}];
const gradle=await access(path.join(root,'.tools/gradle-9.3.0/bin/gradle')).then(()=>path.join(root,'.tools/gradle-9.3.0/bin/gradle'),()=> 'gradle');
const implementations={
 python:`def add(value0, value1): return value0+value1\ndef successor(value0): return value0+1\ndef count(value0): return len(value0)\ndef preserve(value0): return value0\ndef positive(value0): return value0\ndef abstractEcho(value0): return value0\n`,
 javascript:`export function add(a,b){return a+b;}\nexport function successor(a){return a+1;}\nexport function count(a){return [...a].length;}\nexport function preserve(a){return a;}\nexport function positive(a){return a;}\nexport function abstractEcho(a){return a;}\n`,
 typescript:`export function add(a:number,b:number):number|bigint{return a+b;}\nexport function successor(a:number):number|bigint{return a+1;}\nexport function count(a:string):number|bigint{return [...a].length;}\nexport function preserve(a:bigint):number|bigint{return a;}\nexport function positive(a:number):number{return a;}\nexport function abstractEcho(a:bigint):number|bigint{return a;}\n`,
 java:`package example;\npublic final class Refinements { public static Number add(byte a,byte b){return (int)a+b;} public static Number successor(byte a){return (int)a+1;} public static Number count(String a){return a.codePointCount(0,a.length());} public static Number preserve(java.math.BigInteger a){return a;} public static byte positive(byte a){return a;} public static Number abstractEcho(java.math.BigInteger a){return a;} }\n`,
 kotlin:`package example\nobject Refinements { fun add(a:Byte,b:Byte):Number=a.toInt()+b.toInt(); fun successor(a:Byte):Number=a.toInt()+1; fun count(a:String):Number=a.codePointCount(0,a.length); fun preserve(a:java.math.BigInteger):Number=a; fun positive(a:Byte):Byte=a; fun abstractEcho(a:java.math.BigInteger):Number=a }\n`,
 go:`package refinements\nimport "unicode/utf8"\nfunc Add(a,b int8) any {return int16(a)+int16(b)}\nfunc Successor(a int8) any {return int16(a)+1}\nfunc Count(a string) any {return utf8.RuneCountInString(a)}\nfunc Preserve(a uint64) any {return a}\nfunc Positive(a int8) int8 {return a}\nfunc AbstractEcho(a *LawSpecBigInt) any {return a}\n`,
 haskell:`module Example.Refinements where\nimport LawSpecRuntime (IntegerValue,integerValue)\nimport Data.Int\nimport Data.Word\nimport Data.Text (Text)\nimport qualified Data.Text as T\nadd :: Int8 -> Int8 -> IntegerValue\nadd a b = integerValue (toInteger a+toInteger b)\nsuccessor :: Int8 -> IntegerValue\nsuccessor a = integerValue (toInteger a+1)\ncount :: Text -> IntegerValue\ncount = integerValue . T.length\npreserve :: Word64 -> IntegerValue\npreserve = integerValue\npositive :: Int8 -> Int8\npositive = id\nabstractEcho :: Integer -> IntegerValue\nabstractEcho = integerValue\n`
};
for(const target of process.argv.slice(2).length?process.argv.slice(2):targets){
 const dir=path.join(root,'.artifacts',`refinements${bits}`,target);await mkdir(dir,{recursive:true});
 for(const folder of ['src','test','tests','example'])await rm(path.join(dir,folder),{recursive:true,force:true});
 const input={sources,target,machineBits:bits};
 const result=bin?JSON.parse(execFileSync(bin,[],{input:JSON.stringify({method:'planGeneration',...input}),encoding:'utf8',maxBuffer:64*1024*1024})):await compiler.planGeneration(input);
 if(result.diagnostics.length)throw new Error(JSON.stringify(result.diagnostics));
 for(const f of [...Object.entries(templates(target)).map(([path,content])=>({path,content})),...result.files]){const p=path.join(dir,f.path);await mkdir(path.dirname(p),{recursive:true});await writeFile(p,f.ownership==='user'?implementations[target]:f.content);}
 if(['javascript','typescript'].includes(target))await symlink(path.join(root,'.integration',target,'node_modules'),path.join(dir,'node_modules')).catch(e=>{if(e.code!=='EEXIST')throw e});
 if(target==='go')await copyFile(path.join(root,'test/locks/go/go.sum'),path.join(dir,'go.sum'));
 const commands={java:['mvn',['-q','test']],python:[path.join(root,'.integration/python/.venv/bin/python'),['-B','-m','pytest','-q']],javascript:['node',['--test',...result.files.filter(f=>f.path.endsWith('.test.mjs')).map(f=>f.path)]],typescript:['npm',['test']],go:['go',['test','./...']],haskell:['stack',['--no-terminal','test']],kotlin:[gradle,['test','--console=plain']]};
 const [cmd,args]=commands[target];
 await new Promise((resolve,reject)=>{const p=spawn(cmd,args,{cwd:dir,stdio:'inherit'});p.on('exit',code=>code?reject(new Error(`${target} exited ${code}`)):resolve());p.on('error',reject)});
 console.log(`${target}: refinement suite passed`);
 if(process.env.LAWSPEC_MUTANTS==='1') {
  const edits={
   python:[['overflow','return value0+value1','return (value0+value1+128)%256-128'],['precision','def preserve(value0): return value0','def preserve(value0): return float(value0)'],['refinement','def positive(value0): return value0','def positive(value0): return 0'],['standalone','return len(value0)','return 0']],
   javascript:[['overflow','return a+b;','return ((a+b+128)&255)-128;'],['precision','function preserve(a){return a;}','function preserve(a){return Number(a);}'],['refinement','function positive(a){return a;}','function positive(a){return 0;}'],['standalone','return [...a].length;','return 0;']],
   typescript:[['overflow','return a+b;','return ((a+b+128)&255)-128;'],['precision','function preserve(a:bigint):number|bigint{return a;}','function preserve(a:bigint):number|bigint{return Number(a);}'],['refinement','function positive(a:number):number{return a;}','function positive(a:number):number{return 0;}'],['standalone','return [...a].length;','return 0;']],
   java:[['overflow','return (int)a+b;','return (byte)(a+b);'],['precision','preserve(java.math.BigInteger a){return a;}','preserve(java.math.BigInteger a){return a.doubleValue();}'],['refinement','positive(byte a){return a;}','positive(byte a){return 0;}'],['standalone','return a.codePointCount(0,a.length());','return 0;']],
   kotlin:[['overflow','Number=a.toInt()+b.toInt()','Number=(a.toInt()+b.toInt()).toByte()'],['precision','preserve(a:java.math.BigInteger):Number=a;','preserve(a:java.math.BigInteger):Number=a.toDouble();'],['refinement','positive(a:Byte):Byte=a;','positive(a:Byte):Byte=0;'],['standalone','Number=a.codePointCount(0,a.length)','Number=0']],
   go:[['overflow','return int16(a)+int16(b)','return a+b'],['precision','func Preserve(a uint64) any {return a}','func Preserve(a uint64) any {return float64(a)}'],['refinement','func Positive(a int8) int8 {return a}','func Positive(a int8) int8 {return 0}'],['standalone','return utf8.RuneCountInString(a)','return utf8.RuneCountInString(a)-utf8.RuneCountInString(a)']],
   haskell:[['overflow','integerValue (toInteger a+toInteger b)','integerValue (a+b)'],['precision','preserve = integerValue','preserve a = integerValue (round (fromIntegral a :: Double) :: Integer)'],['refinement','positive = id','positive _ = 0'],['standalone','count = integerValue . T.length','count = integerValue . const (0 :: Int) . T.length']],
  };
  const artifact=result.files.find(f=>f.ownership==='user'),adapter=path.join(dir,artifact.path),correct=implementations[target];
  try {for(const [name,before,after] of edits[target]) {
   if(!correct.includes(before))throw new Error(`missing mutant anchor ${target}/${name}`);
   await writeFile(adapter,correct.replace(before,after));
   const report=await new Promise((resolve,reject)=>{const p=spawn(cmd,args,{cwd:dir});let log='';p.stdout.on('data',s=>log+=s);p.stderr.on('data',s=>log+=s);p.on('error',reject);p.on('exit',code=>resolve({code,log}));});
   await writeFile(path.join(dir,`mutant-${name}.log`),report.log);
   if(!report.code||/COMPILATION ERROR|compileTestKotlin FAILED|SyntaxError|\[build failed\]|parse error on input|not in scope/i.test(report.log))throw new Error(`${target}: mutant ${name} escaped or failed to compile`);
   console.log(`${target}: rejected ${name}`);
  }}finally{await writeFile(adapter,correct);}
 }
}
