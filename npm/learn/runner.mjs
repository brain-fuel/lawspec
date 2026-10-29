// All behaviour tests come from LawSpec's generated JavaScript harness.
/** Run the selected generated LawSpec checks and return their actual observations and replay information. ref:DEC-learn-tests-in-lawspec */
export function runnerEntry({
  testFiles,
  seed,
  path = '',
  replayTest = null,
  mode,
  propertyMetadata = {},
})
{
  return `import {details,coverage,beginTest,namedCalls} from './run-support.mjs';
${testFiles.map(file => `import ${JSON.stringify('./' + file)};`).join('\n')}
(async()=>{try{
 globalThis.process={env:{LAWSPEC_SEED:${JSON.stringify(String(seed))},LAWSPEC_STATS:'/browser-stats'}};
 globalThis.__lessonPropertyMetadata=${JSON.stringify(propertyMetadata)};globalThis.__lessonSeed=${seed};globalThis.__lessonReplay=${JSON.stringify({path, test: replayTest})};
 const result={tests:[],properties:details,coverage,seed:${seed},mode:${JSON.stringify(mode)},harnessReports:(globalThis.__harnessReports??=[])};
 const selected=(globalThis.__lawspecTests??[]).filter(row=>${JSON.stringify(mode)}==='sample'?row.name.endsWith(' property'):${JSON.stringify(mode)}==='examples'?!row.name.endsWith(' property')&&!row.name.endsWith(' replay'):true).filter(row=>!${JSON.stringify(replayTest)}||row.name===${JSON.stringify(replayTest)});
 if(!selected.length)throw new Error('Missing LawSpec checks for this execution mode. Add a concrete law or a quantified property.');
 for(const {name,options,fn}of selected){
  beginTest(name);
  if(options?.skip){result.tests.push({name,ok:false,status:'unsupported',error:String(options.skip)});continue;}
  try{await fn();result.tests.push({name,ok:true,status:'passed',calls:[...namedCalls]});}catch(error){result.tests.push({name,ok:false,status:error.code==='LEARN_UNSUPPORTED_HOST'?'unsupported':/incomplete|unknown/i.test(error.message)?'incomplete':'failed',error:String(error.message),calls:[...namedCalls]});}
 }
 result.sampled=details.find(row=>row.status!=='passed')??details[0]??null;
 result.samples=result.sampled?.observations?.slice(0,8).map(row=>row.input)??[];
 result.ok=result.tests.every(row=>row.ok)&&details.every(row=>row.status==='passed');
 postMessage({result});
}catch(error){postMessage({error:String(error?.stack??error)});}})();`;
}
/** Observe native fast-check properties without rewriting their assertions, arbitraries, shrinkers or evidence status. ref:DEC-learn-tests-in-lawspec */
export const supportSource = `import fc from 'fast-check-original';
export const details=[];
export const namedCalls=[];
export const coverage={evaluations:0,empty:0,zero:0,negative:0,duplicates:0};
let testName='',currentCase;
const observations=new WeakMap();
export function beginTest(name){testName=name;namedCalls.length=0;}
function plain(value){
 if(typeof value==='bigint'){const number=Number(value);return Number.isSafeInteger(number)?number:value.toString();}
 if(value===null||typeof value!=='object')return value;
 if(Array.isArray(value))return value.map(plain);
 if(value instanceof Map)return Object.fromEntries([...value].map(([key,item])=>[String(key),plain(item)]));
 return Object.fromEntries(Object.entries(value).map(([key,item])=>[key,plain(item)]));
}
function observe(input){const xs=Array.isArray(input)?input:[input];coverage.evaluations++;if(!xs.length)coverage.empty++;if(xs.includes(0))coverage.zero++;if(xs.some(x=>typeof x==='number'&&x<0))coverage.negative++;if(new Set(xs).size<xs.length)coverage.duplicates++;}
globalThis.__lessonObserveCall=(input,output)=>{const call={input:plain(input),output:plain(output)};if(currentCase)currentCase.calls.push(call);else if(namedCalls.length<100)namedCalls.push(call);};
function property(factory,args){
 const predicate=args.pop(),rows=[];
 const wrapped=(...values)=>{
  const input=plain(values.length===1?values[0]:values),row={input,output:null,ok:null,calls:[]};
  currentCase=row;observe(input);
  const finish=ok=>{row.ok=ok;row.output=row.calls.at(-1)?.output??null;if(rows.length<1000)rows.push(row);currentCase=null;};
  try{const answer=predicate(...values);if(answer&&typeof answer.then==='function')return answer.then(value=>{finish(value!==false);return value;},error=>{finish(false);throw error;});finish(answer!==false);return answer;}catch(error){finish(false);throw error;}
 };
 const result=factory(...args,wrapped);observations.set(result,rows);return result;
}
export function assert(prop,options){
 const replay=globalThis.__lessonReplay;
 const checked=fc.check(prop,{...options,seed:globalThis.__lessonSeed,verbose:2,...(replay?.path&&replay.test===testName?{path:replay.path}:{})});
 const finish=run=>{
 const detail={test:testName,origin:globalThis.__lessonPropertyMetadata?.[testName]?.inputValues?'LawSpec property: counterexample contains law input values':'LawSpec property: counterexample is a generator representation',counterexampleDomain:globalThis.__lessonPropertyMetadata?.[testName]?.inputValues?'law-inputs':'generator-representation',status:run.interrupted||run.failed&&!run.counterexample?'incomplete':run.failed?'failed':'passed',seed:run.seed,path:run.counterexamplePath,counterexample:plain(run.counterexample),numRuns:run.numRuns,numShrinks:run.numShrinks,numSkips:run.numSkips,failures:plain(run.failures),error:run.errorInstance?.message??null,observations:observations.get(prop)??[]};
 if(detail.counterexampleDomain==='law-inputs'&&detail.counterexample){const names=globalThis.__lessonPropertyMetadata?.[testName]?.inputNames??[];detail.inputs=Object.fromEntries(names.map((name,index)=>[name,detail.counterexample[index]]));}
 if(run.errorInstance?.code==='LEARN_UNSUPPORTED_HOST')detail.status='unsupported';
 details.push(detail);
 if(detail.status!=='passed')throw run.errorInstance??new Error('LawSpec property '+detail.status);
 };
 return checked&&typeof checked.then==='function'?checked.then(finish):finish(checked);
}
export default Object.assign({},fc,{assert,property:(...args)=>property(fc.property,args),asyncProperty:(...args)=>property(fc.asyncProperty,args)});`;
/** Register generated node:test callbacks without requiring native Node's test runner. ref:DEC-learn-tests-in-lawspec */
export const nodeTestSource = `const registered=(globalThis.__lawspecTests??=[]);export function test(name,options,fn){registered.push({name:String(name),options:typeof options==='object'?options:{},fn:typeof options==='function'?options:fn});}export default test;export function describe(){const error=new Error('unsupported: parallel suites are not available in the sequential browser host');error.code='LEARN_UNSUPPORTED_HOST';throw error;}`;
