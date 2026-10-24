// Exercise fresh initialization, native completion, unknown results and benchmarks.
// Execution observations remain scoped to the actual generated cases.
// ref:DEC-prolog-janus
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdir,readFile,readdir,rm,writeFile} from 'node:fs/promises';
import path from 'node:path';

const exec=promisify(execFile), repo=path.resolve(import.meta.dirname,'..');
const cli=path.join(repo,'npm/bin/lawspec.mjs');
const bits=Number(process.env.LAWSPEC_MACHINE_BITS??64), compact=process.env.LAWSPEC_MINIFY==='1';
assert.ok([32,64].includes(bits));
const project=path.join(repo,'.artifacts/prolog-cli-integration',`${bits}-${compact}`);
await rm(project,{recursive:true,force:true});await mkdir(project,{recursive:true});
const python=process.env.LAWSPEC_PYTHON_EXECUTABLE??path.join(repo,'.integration/prolog/.venv/bin/python');
let step=0;
async function call(command,flags=[],pass=true,extraEnv={}){
  let result;
  try {result=await exec(process.execPath,[cli,command,...flags],{cwd:project,
    env:{...process.env,...extraEnv},timeout:180000,maxBuffer:16*1024*1024});}
  catch(error){result=error;}
  const output=(result.stdout??'')+(result.stderr??'');
  await mkdir(path.join(project,'.lawspec/logs'),{recursive:true});
  await writeFile(path.join(project,'.lawspec/logs',`${++step}-${command}.log`),output);
  assert.ok(!result.killed&&!result.signal,output);
  if(pass)assert.equal(result.code??0,0,output);
  else assert.ok(Number.isInteger(result.code)&&result.code>0,output);
  return flags.includes('--json')?JSON.parse(result.stdout):output;
}

await call('init',['--target','prolog','--machine-bits',String(bits)]);
const configFile=path.join(project,'lawspec.json');
const config=JSON.parse(await readFile(configFile,'utf8'));
config.sources=['laws/basic.lawspec','laws/benchmark.lawspec','laws/benchmark-testing.lawspec'];
config.verification.layers=['exhaustive','property','examples','runtime','model'];
Object.assign(config.targets[0],{python,sourceDir:'app/code',testDir:'checks/generated'});
await writeFile(configFile,JSON.stringify(config,null,2)+'\n');
const manifest=path.join(project,'pyproject.toml');
await writeFile(manifest,(await readFile(manifest,'utf8'))
  .replaceAll('["src"]','["app/code"]').replaceAll('["tests"]','["checks/generated"]'));
await writeFile(path.join(project,'laws/basic.lawspec'),await readFile(path.join(repo,'test/fixtures/prolog/basic.lawspec')));
await writeFile(path.join(project,'laws/benchmark.lawspec'),`unit example.benchmarkProbe
measure :: Unit -> Unit
end unit
`);
await writeFile(path.join(project,'laws/benchmark-testing.lawspec'),`harness example.benchmarkTesting for example.benchmarkProbe is
  benchmark \`measured native call\` is measure unitValue end benchmark
end harness
`);
await call('generate',compact?['--minify']:[]);
const adapter=path.join(project,'app/code/example/prologBasic.pl');
const original=await readFile(path.join(repo,'acceptance/prolog-bridge/prolog/files/src/example/prologBasic.pl'),'utf8');
await writeFile(adapter,original);
const module='example_benchmark_probe';
await writeFile(path.join(project,'app/code/example/benchmarkProbe.pl'),
  `:- module(${module},[ls_measure/2]).\n:- use_module(library(janus)).\nls_measure(U,U) :- py_call(benchmark_audit:record()).\n`);
await writeFile(path.join(project,'app/code/benchmark_audit.py'),
  `from pathlib import Path\ndef record():\n    with Path('.lawspec/benchmark.calls').open('a') as output:\n        output.write('called\\n')\n`);
const reports=await call('doctor',['--json']);
assert.equal(reports[0].ok,true);assert.equal(reports[0].versions.ready,true);
async function test(flags=[],pass=true){return (await call('test',[
  '--json',...(compact?['--minify']:[]),'--seed','1920217000',...flags],pass))[0];}
const initial=await test(['--fresh']);assert.equal(initial.ok,true);assert.equal(initial.ran.length,3);
assert.deepEqual((await test()).ran,[]);
const optimized=await call('test',['--json',...(compact?['--minify']:[])],false,{PYTHONOPTIMIZE:'1'});
assert.ok(optimized.diagnostics.some(diagnostic=>diagnostic.code==='cli'));
assert.match(JSON.stringify(optimized),/require enabled Python assertions/);
assert.equal(await readFile(path.join(project,'.lawspec/benchmark.calls'),'utf8').catch(()=>''),'');
for(let run=0;run<2;run++){
  await rm(path.join(project,'.lawspec/benchmark.calls'),{force:true});
  const measured=await test(['--benchmarks']);assert.equal(measured.ok,true);assert.deepEqual(measured.ran,[]);
  assert.equal(measured.benchmarks.length,1);
  const calls=(await readFile(path.join(project,'.lawspec/benchmark.calls'),'utf8')).trim().split('\n');
  assert.equal(calls.length,measured.benchmarks[0].iterations);
}
await writeFile(adapter,original.replace('ls_flag(_, false).',
  'ls_flag(_, _) :- throw(lawspec_incomplete("bounded native computation")).'));
await test([],false);
const results=path.join(project,'.lawspec/results');
const records=await Promise.all((await readdir(results)).filter(file=>file.endsWith('.json'))
  .map(async file=>JSON.parse(await readFile(path.join(results,file),'utf8'))));
const unknown=records.flatMap(record=>Object.values(record.attempts??{})).find(row=>row.check.name==='test_falsevalue');
assert.ok(unknown);assert.equal(unknown.outcome,'incomplete');
assert.ok(unknown.tests.some(row=>row.status==='incomplete'));
assert.ok(unknown.tests.every(row=>['incomplete','skipped'].includes(row.status)));
assert.equal(unknown.searchCompleteness,'not-established');
await writeFile(adapter,original);
assert.equal((await test()).ok,true);
await call('generate',['--check',...(compact?['--minify']:[])]);
await writeFile(path.join(project,'laws/selection.lawspec'),`unit example.selection
echo :: Bool -> Bool
law echoes is
  definition: for all (x :: Bool) => echo x must be x end for all end definition
  example known: x = true expect echo x = true end example
end law
end unit
`);
config.sources=['laws/selection.lawspec'];
const resultFile=path.join(results,(await readdir(results)).find(file=>file.endsWith('.json')));
for(const [layers,cases]of [[['examples'],1],[['exhaustive'],2],[[],0]]){
  config.verification.layers=layers;await writeFile(configFile,JSON.stringify(config,null,2)+'\n');
  await call('generate',compact?['--minify']:[]);
  const identity='example_selection';
  await writeFile(path.join(project,'app/code/example/selection.pl'),
    `:- module(${identity},[ls_echo/2]).\nls_echo(X,X).\n`);
  const selected=cases?await test(['--fresh']):await call('test',['--json','--fresh',...(compact?['--minify']:[])]);
  if(cases){
    assert.equal(selected.ok,true);assert.equal(selected.ran.length,1,JSON.stringify(layers));
    const attempts=JSON.parse(await readFile(resultFile,'utf8')).attempts;
    const observed=Object.values(attempts).find(row=>row.check.name==='test_echoes');
    assert.equal(observed.outcome,'passed');assert.equal(observed.tests.length,cases);
  } else {
    assert.equal(selected.testsExecuted,0);assert.deepEqual(selected.verification.layers,[]);
    assert.ok(selected.evidence.filter(row=>row.stage==='law').every(row=>row.status==='not-verified'));
  }
  assert.equal(JSON.parse(await readFile(path.join(project,'lawspec-prolog-tests.json'),'utf8')).length,cases?1:0);
}
console.log(`PASS Prolog fresh CLI, custom layout, doctor, cache, benchmark calls, explicit incomplete evidence and independent layer selection (${bits}, compact=${compact})`);
