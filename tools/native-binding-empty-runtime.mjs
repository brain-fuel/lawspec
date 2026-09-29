// Generator-only configurations keep source independent of test frameworks.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';
const root=path.resolve(import.meta.dirname,'..');
const compiler=process.env.LAWSPEC_CORE;
assert.ok(compiler,'Set LAWSPEC_CORE');
const wasm=await createCompiler();
for (const target of ['python','javascript','typescript','java','kotlin','go']) {
  const request={schemaVersion:4,method:'planGeneration',target,
    sources:[{path:'empty.lawspec',content:'unit empty'}],
    nativeBindings:{generators:[{type:'Unit',factory:target==='go' ? ['NativeUnits'] : ['domain','Factories','units']}]}};
  const result=JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),
    encoding:'utf8',maxBuffer:32*1024*1024}));
  assert.deepEqual(result.diagnostics,[]);
  assert.deepEqual(await wasm.planGeneration(request),result,'Generator-only native/WASM parity');
  assert.ok(!result.files.some(file=>file.placement==='test' && file.path.toLowerCase().includes('empty')),
    'Do not emit tests importing an adapter for a unit with no properties');
  const directory=path.join(root,'.artifacts/native-binding-empty',target);
  const sources=result.files.filter(file=>file.placement==='source');
  if (target==='go' && sources.length===0) {
    assert.deepEqual(result.files,[], 'An unused Go generator must not emit orphan test helpers');
    console.log('go: unused generator-only unit emits no orphan artifacts (native/WASM parity)');
    continue;
  }
  await mkdir(directory,{recursive:true});
  for (const file of sources) {
    const destination=path.join(directory,file.path);
    await mkdir(path.dirname(destination),{recursive:true});
    await writeFile(destination,file.content);
  }
  if (target==='python') {
    execFileSync(process.env.LAWSPEC_PYTHON ?? 'python3.13',['-B','-c','import lawspec_native'],{
      cwd:directory,env:{...process.env,PYTHONPATH:path.join(directory,'src')},stdio:'inherit'});
  } else if (target==='go') {
    await writeFile(path.join(directory,'go.mod'),'module fixture\n\ngo 1.24.0\n');
    execFileSync('go',['build','./...'],{cwd:directory,stdio:'inherit',env:{...process.env,
      GOCACHE:path.join(root,'.artifacts/go-cache'),GOTOOLCHAIN:'local',GOPROXY:'off'}});
  } else if (target==='java' || target==='kotlin') {
    await mkdir(path.join(directory,'classes'),{recursive:true});
    execFileSync('javac',['--release','25','-d',path.join(directory,'classes'),
      ...sources.filter(file=>file.path.endsWith('.java')).map(file=>path.join(directory,file.path))],{stdio:'inherit'});
    if (target==='kotlin') execFileSync('kotlinc',['-jvm-target','25','-classpath',path.join(directory,'classes'),
      ...sources.filter(file=>file.path.endsWith('.kt')).map(file=>path.join(directory,file.path)),
      '-d',path.join(directory,'source.jar')],{stdio:'inherit'});
  } else {
    await writeFile(path.join(directory,'package.json'),'{"type":"module"}\n');
    if (target==='typescript') {
      const tsc=path.join(root,'.artifacts/web-data-deps/typescript/bin/tsc');
      execFileSync(process.execPath,[tsc,'--target','ES2022','--module','NodeNext',
        '--strict','--skipLibCheck','--outDir',path.join(directory,'dist'),
        ...sources.map(file=>path.join(directory,file.path))],{stdio:'inherit'});
    }
    const module=target==='typescript' ? './dist/lawspec_native.js' : './src/lawspec_native.mjs';
    execFileSync(process.execPath,['--input-type=module','-e',`await import('${module}');`],{
      cwd:directory,stdio:'inherit'});
  }
  console.log(`${target}: generator-only source runtime compiles/loads without a test framework`);
}
