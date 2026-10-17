// Execute migrated Chapter 6 examples and independent native codec oracles.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {existsSync} from 'node:fs';
import {mkdir,mkdtemp,readFile,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';
import {writeMigration} from '../npm/migration-write.mjs';
import {templates} from '../npm/templates.mjs';
import {safePath,planWrites,applyWrites} from '../npm/files.mjs';
import {executedTests} from '../npm/test-command.mjs';

const root=path.resolve(import.meta.dirname,'..');
const digest=bytes=>createHash('sha256').update(bytes).digest('hex');
const bits=Number(process.env.LAWSPEC_MACHINE_BITS??64);
assert.ok(bits===32||bits===64);
const minify=process.env.LAWSPEC_MINIFY==='1';
const args=process.argv.slice(2);
assert.ok(args.length===0||(args.length===1&&args[0]==='--property'),'Use --property or no arguments');
const local=path.join(root,'.integration/python/.venv/bin/python');
const python=process.env.LAWSPEC_PYTHON_EXECUTABLE??(existsSync(local)?local:'python3');
const artifactRoot=path.join(root,'.artifacts/chapter6-oracles');
await mkdir(artifactRoot,{recursive:true});
const directory=await mkdtemp(path.join(artifactRoot,`python-${bits}-${minify}-`));
const project=path.join(directory,'project');
await mkdir(project);
const seed=process.env.LAWSPEC_SEED??'6061';
assert.match(seed,/^\d+$/,'LAWSPEC_SEED must be a nonnegative integer');
const environment={...process.env,PYTHONDONTWRITEBYTECODE:'1',LAWSPEC_SEED:seed};
let step=0;
async function run(label,arguments_,{pass=true}={}) {
  console.log('python '+label);
  const process=spawnSync(python,['-B',...arguments_],{cwd:project,env:environment,encoding:'utf8',maxBuffer:32*1024*1024});
  const output=(process.stdout??'')+(process.stderr??'');
  await writeFile(path.join(directory,`${String(++step).padStart(2,'0')}-${label}.log`),output);
  assert.equal(process.error,undefined,String(process.error));
  if(pass) assert.equal(process.status,0,output);
  else assert.ok(process.status>0,`Mutant unexpectedly passed: ${label}\n${output}`);
  return {status:process.status,output,stdout:process.stdout};
}
function native(method,request) {
  const process=spawnSync(environment.LAWSPEC_CORE,[],{input:JSON.stringify({...request,method}),encoding:'utf8',maxBuffer:128*1024*1024});
  assert.equal(process.status,0,process.stderr);
  return JSON.parse(process.stdout);
}
const compiler=environment.LAWSPEC_CORE?Object.fromEntries(
  ['check','migrationBaseline','migrationComparison','migrationBindings','migrationGeneration','planGeneration']
    .map(method=>[method,async request=>native(method,request)])):await createCompiler();
const original=await readFile(path.join(root,'test/fixtures/migration-chap06-0.24.lawspec'),'utf8');
const sourceSha256=digest(original);
assert.equal(sourceSha256,'07d8116b847aa80e044ad3ea2cbc8317bc949a0c4fe07b560e513d6fa0bfaf06');
const sources=[{path:'chap06.lawspec',content:original}];
const configurationText=JSON.stringify({version:1,sources:['chap06.lawspec'],
  targets:[{language:'python',root:'project'}],machineBits:bits},null,2)+'\n';
await writeFile(path.join(directory,'chap06.lawspec'),original);
await writeFile(path.join(directory,'lawspec.json'),configurationText);
const migration=await writeMigration(compiler,directory,'lawspec.json',configurationText,{sources,machineBits:bits});
assert.deepEqual(migration.diagnostics,[]);
assert.deepEqual(migration.sourcePreview.diagnostics,[]);
assert.equal(migration.sourcePreview.canonicalCheck.status,'accepted');
assert.equal(migration.sourcePreview.canonicalCheck.intrinsicDefinitionChecks,true);
assert.equal(migration.validated,true);
assert.equal(migration.validation.status,'validated-under-existing-assumptions');
assert.equal(migration.validation.lawVerification,'not-established-by-migration');
assert.deepEqual(migration.filesWritten,['chap06.lawspec','lawspec.json']);
assert.equal(migration.baseline.laws.length,23);
assert.equal(migration.baseline.definitions.length,25);
assert.equal(migration.baseline.types.length,7);
const nodes=migration.baseline.sourceSyntax[0].nodes;
for(const [kind,count] of [['table-row',65],['example',1],['declaration.refinement',2]])
  assert.equal(nodes.filter(node=>node.kind===kind).length,count);
const migrated=await readFile(path.join(directory,'chap06.lawspec'),'utf8');
assert.equal(migrated,migration.sourcePreview.sources[0].content);
await writeFile(path.join(directory,'chap06-preview.lawspec'),migrated);
// Authoring follows the validated semantic migration as a separate adoption.
// Its mappings and names do not claim unchanged complete-source fingerprints.
const authored=await readFile(path.join(root,'examples/chap06/assembler.lawspec'),'utf8');
assert.equal(authored.match(/^(function|mapping) /gm).length,25);
assert.equal(authored.match(/^mapping /gm).length,6);
assert.equal(authored.match(/^type /gm).length,7);
assert.equal(authored.match(/^refinement /gm).length,2);
assert.equal(authored.match(/^  description:/gm).length,23);
assert.equal(authored.match(/^\s+example /gm).length,1);
assert.equal(authored.replace(/^mapping .*?^end mapping\n/gms,'').match(/^\s+row /gm).length,65);
const canonical=[{path:'chap06.lawspec',content:authored}];
await writeFile(path.join(directory,'chap06.lawspec'),authored);
const layers=args[0]==='--property'?['property','examples']:['examples'];
const request={schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers},machineBits:bits,minify,target:'python',sources:canonical};
const plan=await compiler.planGeneration(request);
assert.deepEqual(plan.diagnostics,[]);
const chapter=plan.tests.filter(test=>test.unit==='nand2tetris.chap06');
assert.equal(chapter.length,23);
async function write(relative,content) {
  const destination=await safePath(project,relative);
  await mkdir(path.dirname(destination),{recursive:true});
  await writeFile(destination,content);
}
for(const [file,content] of Object.entries(templates('python',{minify}))) await write(file,content);
await applyWrites([await planWrites(project,plan.files)]);
const adapters=plan.files.filter(file=>file.ownership==='user');
const adapter=adapters.find(file=>file.path==='src/nand2tetris/chap06.py');
assert.ok(adapter);
for(const file of adapters.filter(file=>file!==adapter))
  assert.ok(!/\bdef\s/.test(file.content),'No additional adapter implementation may be left unwired: '+file.path);
const candidate=await readFile(path.join(root,'examples/chap06/python/hack_assembler.py'),'utf8');
await write('src/hack_assembler.py',candidate);
await write(adapter.path,'from hack_assembler import assemble\n');
await write('Program.asm','@2\nD=A\n@3\nD=D+A\n@0\nM=D\n');
await run('native-cli',['src/hack_assembler.py','Program.asm']);
assert.equal(await readFile(path.join(project,'Program.hack'),'utf8'),
  '0000000000000010\n1110110000010000\n0000000000000011\n1110000010010000\n0000000000000000\n1110001100001000\n');
await write('Empty.asm','// no instructions\n');
await run('empty-native-cli',['src/hack_assembler.py','Empty.asm']);
assert.equal((await readFile(path.join(project,'Empty.hack'))).length,0);
const testFiles=[...new Set(chapter.map(test=>test.file))];
assert.equal(testFiles.length,1);
const tested=await run('generated-tests',['-m','pytest','-q',...testFiles,'--junitxml=chapter6.xml']);
const xml=await readFile(path.join(project,'chapter6.xml'),'utf8');
assert.ok(!/<(?:failure|error|skipped)\b/.test(xml),xml);
const tests=await executedTests({kind:'junit',files:['chapter6.xml']},tested.output,project,Date.now());
assert.equal(tests.filter(test=>test.name.includes('__example')).length,66,'65 independent table rows plus one named example');
assert.equal(new Set(tests.map(test=>test.name)).size,tests.length,'Each native check runs once');
const generated={examples:0,properties:0,boundaries:0,replayHooks:0,total:tests.length,lawsExercised:0};
for(const entry of chapter) {
  let exercised=false;
  for(const test of tests.filter(test=>test.name.startsWith(entry.name+'__'))) {
    const kind=test.name.slice(entry.name.length+2);
    if(/^example\d+$/.test(kind)) { generated.examples++;exercised=true; }
    else if(/^boundary\d+$/.test(kind)) { generated.boundaries++;exercised=true; }
    else if(kind==='property') { generated.properties++;exercised=true; }
    else if(kind==='replay') generated.replayHooks++;
    else assert.fail('Unknown generated native check: '+test.name);
  }
  if(exercised) generated.lawsExercised++;
  if(args[0]==='--property') assert.ok(exercised,'No executed property, boundary or example for '+entry.law);
}
assert.equal(generated.examples+generated.properties+generated.boundaries+generated.replayHooks,tests.length);
if(args.length===0) assert.equal(tests.length,66);
const checker=path.join(root,'tools/chapter6-native-oracles.py');
const fixture=path.join(root,'test/fixtures/chapter6');
const candidatePath=path.join(project,'src/hack_assembler.py');
const oracleArguments=(file,generated=project)=>[checker,'--candidate',file,'--fixture',fixture,'--generated',generated];
const checked=await run('independent-oracles',oracleArguments(candidatePath));
const evidence=JSON.parse(checked.stdout);
assert.deepEqual(evidence.counts,{aInstructions:32768,cInstructions:1792,statefulPrograms:13,repeatedInvocationIndependence:true});
const mutants=[
  {name:'address-high-bit',before:'output.append(f"{address:016b}")',after:'output.append(f"{address & 0x3fff:016b}")',suite:'a',diagnostic:'ORACLE_A'},
  {name:'memory-computation-bit',before:'comp = COMPUTATIONS[computation]',after:'comp = COMPUTATIONS[computation] & 0b0111111',suite:'c',diagnostic:'ORACLE_C'},
  {name:'destination-bits',before:'DESTINATIONS = {"A": 4, "D": 2, "M": 1}',after:'DESTINATIONS = {"A": 2, "D": 4, "M": 1}',suite:'c',diagnostic:'ORACLE_C'},
  {name:'physical-line-width',before:'output.append(f"{address:016b}")',after:'output.append(f"{address:015b}")',suite:'a',diagnostic:'ORACLE_A'},
  {name:'symbol-table-leak',before:'symbols = dict(PREDEFINED)',after:'symbols = PREDEFINED',suite:'state',diagnostic:'ORACLE_STATE'},
];
const rejected=[];
for(const mutant of mutants) {
  assert.equal(candidate.split(mutant.before).length,2,mutant.name+' must change exactly one operation');
  const file=path.join(directory,mutant.name+'.py');
  await writeFile(file,candidate.replace(mutant.before,mutant.after));
  const result=await run(mutant.name,[...oracleArguments(file),'--suite',mutant.suite],{pass:false});
  assert.ok(result.output.includes(mutant.diagnostic),result.output);
  rejected.push({name:mutant.name,suite:mutant.suite,diagnostic:mutant.diagnostic});
}
const before='row CZero, 42',after='row CZero, 43';
assert.equal(canonical[0].content.split(before).length,2,'Checked computation-table mutant must change exactly one row');
const altered=await compiler.planGeneration({...request,verification:{layers:[]},
  sources:canonical.map(source=>({...source,content:source.content.replace(before,after)}))});
assert.deepEqual(altered.diagnostics,[]);
assert.equal(altered.verification.intrinsicDefinitionChecks,true);
assert.equal(altered.verification.selection,'no-selected-checks');
const mutantProject=path.join(directory,'checked-table');
await mkdir(mutantProject);
await applyWrites([await planWrites(mutantProject,altered.files)]);
const wrongOracle=await run('checked-computation-table',[...oracleArguments(candidatePath,mutantProject),'--suite','c'],{pass:false});
assert.match(wrongOracle.output,/ORACLE_C:.*checked computeWord/,
  'The external vectors must reject the changed checked specification independently of the correct native assembler');
rejected.push({name:'checked-computation-table',suite:'c',diagnostic:'ORACLE_C',subject:'checked-specification',lawVerification:'no-selected-checks'});
const result={version:1,target:'python',machineBits:bits,minify,compiler:environment.LAWSPEC_CORE?'native':'wasm',
  sourceSha256,migratedSourceSha256:digest(migrated),authoredSourceSha256:digest(authored),candidateSha256:digest(candidate),
  compilerSha256:digest(await readFile(environment.LAWSPEC_CORE??path.join(root,'npm/core.wasm'))),
  seed,generation:plan.generation,verificationLayers:layers,generated,nativeCliPrograms:2,oracle:evidence,mutants:rejected,
  migrationValidated:migration.validated,migrationValidation:migration.validation,
  authoredInventory:{laws:23,tableRows:65,namedExamples:1,definitions:25,mappings:6,dataTypes:7,refinements:2},
  scope:'Python native conformance and emitted checked codecs of the published authoring pass; validated project migration is recorded separately; remaining native targets are separate gates'};
await writeFile(path.join(directory,'evidence.json'),JSON.stringify(result,null,2)+'\n');
console.log(JSON.stringify({...result,directory}));
