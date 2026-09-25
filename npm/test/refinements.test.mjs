import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile,mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
import path from 'node:path';
import os from 'node:os';
import {createCompiler} from '../api.mjs';
const compiler=await createCompiler();
const sources=content=>[{path:'refinement.lawspec',content}];
const content=await readFile(new URL('../examples/specs/refinements.lawspec',import.meta.url),'utf8');
const compiled=await compiler.planGeneration({sources:sources(content),target:'javascript'});
const runtimeCode=compiled.files?.find(f=>f.path.endsWith('lawspec_runtime.mjs'))?.content;
const runtime=runtimeCode?await import('data:text/javascript;base64,'+Buffer.from(runtimeCode).toString('base64')):null;
test('API retains parameter kinds, contracts, domains and generation settings',async()=>{
 assert.deepEqual(compiled.diagnostics,[]);
 assert.equal(compiled.refinements.length,3);
 assert.equal(compiled.refinements[0].declaration.refinementParameters[0][1].contents,'Type');
 assert.ok(compiled.contracts.length>=5);
 const overflow=compiled.laws.find(l=>l.name==='overflow pairs');
 assert.equal(overflow.inputs[1].inputRefinements.length,1);
 assert.equal(overflow.generationPlan[1].domainBounds.length,1);
 assert.equal(overflow.original.examples[0].expectations[0].expected.type,'Integer');
 const result=await compiler.check({sources:sources(content),generation:{cases:7,maxAttempts:80,maxShrinks:9,exhaustiveLimit:32}});
 assert.deepEqual(result.diagnostics,[]);assert.deepEqual(result.generation,{cases:7,maxAttempts:80,maxShrinks:9,exhaustiveLimit:32});
 assert.equal(result.laws[0].generation.cases,7);
 assert.ok((await compiler.check({sources:[],generation:{cases:0}})).diagnostics.length);
});
function overflowDomains(){return [
 [(prefix,seed)=>runtime.domainCandidates('Int8',seed,64,[],[-128,0,1,127]),()=>true],
 [(prefix,seed)=>runtime.domainCandidates('Int8',seed,64,[['>',127-prefix[0]]],[]),prefix=>prefix[0]+prefix[1]>127],
];}
test('dependent generation backtracks and never returns an impossible prefix',()=>{
 assert.ok(runtime);
 assert.deepEqual(runtime.domainCandidates('Int8',0,64,[['>',127]],[]),[]);
 for(let seed=0;seed<300;seed++){
  const [x,y]=runtime.generateTuple(overflowDomains(),seed,10000);
  assert.ok(x>0&&x<=127&&y>=128-x&&y<=127,`${x}, ${y}`);
 }
});
test('shrinking preserves dependent refinements and repairs later values',()=>{
 let calls=0;
 assert.throws(()=>runtime.refinedCase(overflowDomains(),77,10000,1000,values=>{
  const [x,y]=values;calls++;
  assert.ok(x>0&&x<=127&&y>=128-x&&y<=127,'shrinker left refinement domain');
  throw new Error('deliberate overflow');
 }),/deliberate overflow.*refined counterexample=1,127/);
 assert.ok(calls>1);
});
test('search exhaustion is explicit and predicate errors are not discarded',()=>{
 assert.throws(()=>runtime.generateTuple([[()=>[0],()=>false]],0,25),/refinement-generation-exhausted after 25 attempts/);
 assert.throws(()=>runtime.generateTuple([[()=>[0],()=>{throw new Error('predicate division by zero');}]],0,25),/predicate division by zero/);
});
test('abstract integers accept exact native representations and reject precision loss',()=>{
 assert.equal(runtime.validate(128,'Integer'),128n);
 assert.equal(runtime.validate(18446744073709551615n,'Integer'),18446744073709551615n);
 for(const bad of [true,1.5,NaN,Infinity,9007199254740992,new runtime.Decimal(1n),new runtime.Rational(1n)])assert.throws(()=>runtime.validate(bad,'Integer'),/Integer/);
});
test('standalone contracts evaluate each native call once',async()=>{
 const text='unit calls\nf :: (x :: Unit) -> (result :: Integer where result == 1)';
 const result=await compiler.planGeneration({sources:sources(text),target:'javascript'});
 assert.deepEqual(result.diagnostics,[]);
 const dir=await mkdtemp(path.join(os.tmpdir(),'lawspec-contract-'));
 try{
  for(const f of result.files){const p=path.join(dir,f.path);await mkdir(path.dirname(p),{recursive:true});await writeFile(p,f.ownership==='user'?'export let calls=0; export function f(x){calls++;return 1;}':f.content);}
  const testFile=result.files.find(f=>f.placement==='test').path;
  const p=path.join(dir,testFile);
  await writeFile(p,await readFile(p,'utf8')+'\nimport {after} from "node:test"; after(()=>assert.equal(impl.calls,1));\n');
  execFileSync('node',['--test',testFile],{cwd:dir,stdio:'pipe'});
 }finally{await rm(dir,{recursive:true,force:true});}
});
