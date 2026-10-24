// Generated from templates/tools/parity.mjs by lawspec-dev generate. Do not edit.
import {parseManifest, writeManifest} from '../npm/component.mjs';
// Compare complete compiler responses across native and WASM boundaries.
// Matching rejections are counted separately from accepted backend generation.
import {execFileSync} from 'node:child_process';
import {readFile,readdir} from 'node:fs/promises';
import assert from 'node:assert/strict';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';
import {targets,programTargets,artifactTargets} from '../npm/templates.mjs';
import {collectSources} from '../npm/files.mjs';
const root=path.resolve(import.meta.dirname,'..');
const bin=process.env.LAWSPEC_CORE||path.join(execFileSync('stack',['path','--local-install-root'],{
  cwd:root,encoding:'utf8'}).trim(),'bin/lawspec-core');
const requested=process.argv.slice(2).filter(arg=>arg!=='--canonical');
const paths=requested.length?requested.map(name=>path.resolve(name)):
  (await readdir(path.join(root,'examples/specs'))).filter(name=>name.endsWith('.lawspec')).sort()
    .map(name=>path.join(root,'examples/specs',name));
const reference='npm/starter-rc1.lawspec';
const content=await readFile(path.join(root,reference),'utf8');
const invalid=content.replace('row -42,','row 2147483648,');
const unicode=content.replace('Converting an integer','λ 日本語 😀 Converting an integer');
assert.notEqual(invalid,content,'The invalid-input probe must change its source');
assert.notEqual(unicode,content,'The Unicode probe must change its source');
const fixtures=[...(await Promise.all(paths.map(name=>readFile(name,'utf8')))),invalid,unicode];
const compiler=await createCompiler(),counts={responses:0,accepted:0,rejected:0,generationAccepted:0,generationRejected:0};
const artifactContent=await readFile(path.join(root,'test/fixtures/artifact-configuration.lawspec'),'utf8');
const artifactProbes=[
  ['antlr4','generic input identities',await readFile(path.join(root,'test/fixtures/artifact-antlr-inputs.lawspec'),'utf8'),false],
  ['antlr4','closed indexed input',await readFile(path.join(root,'test/fixtures/artifact-antlr-indexed-input.lawspec'),'utf8'),true],
  ['hcl','unbounded integer','unit exact\nvalue :: Unit -> Integer\nend unit',true],
  ['hcl','normalization','unit exact\nfunction value (u :: Unit) -> Text is "e\u0301" end function\nend unit',true],
  ['hcl','unassigned normalization data','unit exact\nfunction value (u :: Unit) -> Text is "\u{1fae9}" end function\nend unit',true],
  ['yaml','unsupported scalar','unit exact\nvalue :: Unit -> Rational\nend unit',true],
  ['yaml','incomplete configuration','unit incomplete\nvalue :: Unit -> UInt16\nend unit',false],
  ['yaml','empty type','unit empty\ntype Empty is one of end type\nend unit',false],
  ['yaml','unbounded exact value',`unit exact\nfunction value (u :: Unit) -> Integer is ${2n**4096n+17n} end function\nend unit`,false],
];
const options={schemaVersion:5,languageProfile:'1.0-rc.2',verification:{layers:['proof','exhaustive','property','examples','runtime','model']}};
async function compare(method,input,label,{generation=false,required=false,rejected=false}={}){
  const native=JSON.parse(execFileSync(bin,[],{input:JSON.stringify({...input,method}),encoding:'utf8',maxBuffer:128*1024*1024}));
  const wasm=await compiler[method](input);assert.deepEqual(wasm,native,label);
  assert.equal(native.schemaVersion,5,label);counts.responses++;
  const accepted=native.diagnostics.length===0;counts[accepted?'accepted':'rejected']++;
  if(rejected)assert.ok(!accepted,label+' admitted an out-of-range input');
  if(generation)counts[accepted?'generationAccepted':'generationRejected']++;
  if(required){assert.deepEqual(native.diagnostics,[],label);if(generation)assert.ok(native.files.length,label+' emitted no artifacts');}
  return native;
}
for(const machineBits of [32,64]){
  for(const [index,text]of fixtures.entries()){
    const input={...options,sources:[{path:'fixture.lawspec',content:text}],machineBits};
    for(const method of ['check','expand'])await compare(method,input,`${method}:${index}:${machineBits}`,{rejected:index===paths.length});
  }
  console.log('Frontend full-response parity:',fixtures.length,'fixtures,',machineBits,'bits');
}
for(const machineBits of [32,64])for(const minify of [false,true]){
  for(const [index,text]of fixtures.entries())for(const target of targets){
    const input={...options,sources:[{path:'fixture.lawspec',content:text}],target,machineBits,minify};
    await compare('planGeneration',input,
      `generation:${index}:${target}:${machineBits}:${minify}`,{generation:true,rejected:index===paths.length});
  }
  // Require actual accepted output from every backend in every profile, in
  // addition to comparing any honest unsupported/rejected fixture responses.
  for(const target of programTargets){
    const input={...options,sources:[{path:'codec.lawspec',content}],target,machineBits,minify};
    await compare('planGeneration',input,
      `required codec:${target}:${machineBits}:${minify}`,{generation:true,required:true});
  }
  for(const target of artifactTargets){
    const input={...options,sources:[{path:'configuration.lawspec',content:artifactContent}],target,machineBits,minify};
    await compare('planGeneration',input,`required artifact:${target}:${machineBits}:${minify}`,{generation:true,required:true});
    await compare('planGeneration',{...input,verification:{layers:[]},sources:[{path:'invalid.lawspec',content:
      'unit invalid\nfunction bad (u :: Unit) -> UInt8 is 300 end function\nend unit'}]},
      `intrinsic artifact validation:${target}:${machineBits}:${minify}`,{generation:true,rejected:true});
  }
  for(const [target,label,content,rejected]of artifactProbes){
    await compare('planGeneration',{...options,verification:{layers:[]},target,machineBits,minify,
      sources:[{path:'probe.lawspec',content}]},`artifact ${label}:${machineBits}:${minify}`,
      {generation:true,rejected,required:!rejected});
  }
  console.log('Generation full-response parity:',machineBits,'bits, compact=',minify);
}
const projectRoot=path.join(root,'examples/packages/orders');
const config=parseManifest(await readFile(path.join(projectRoot,'lawspec.edn'),'utf8'));
const packages=await Promise.all(config.packages.map(async name=>{
  const directory=path.resolve(projectRoot,name);
  const manifest=parseManifest(await readFile(path.join(directory,'lawspec.edn'),'utf8'));
  return {name:manifest.package.name,version:manifest.package.version,...(manifest.dependencies?{dependencies:manifest.dependencies}:{}),
    sources:await collectSources(directory,manifest.sources)};
}));
const packaged={...options,sources:await collectSources(projectRoot,config.sources),dependencies:config.dependencies,packages};
for(const method of ['check','expand'])await compare(method,packaged,`canonical packages:${method}`,{required:true});
for(const target of programTargets)await compare('planGeneration',{...packaged,target},
  `canonical packages:${target}`,{generation:true,required:true});
console.log('Complete native/WASM response counts:',JSON.stringify(counts));
