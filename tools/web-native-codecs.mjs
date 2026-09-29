// Compile and execute application-owned JS/TS bindings and native arbitraries.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile, symlink} from 'node:fs/promises';
import path from 'node:path';
import {createRequire} from 'node:module';
import {createCompiler} from '../npm/api.mjs';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
assert.ok(compiler, 'Set LAWSPEC_CORE');
const wasm = await createCompiler();
const tsc = path.join(root,'.artifacts/web-data-deps/typescript/bin/tsc');
const typescript = createRequire(import.meta.url)(path.join(root,
  '.artifacts/web-data-deps/typescript/lib/typescript.js'));
const dependencies = path.join(root,'.artifacts/lists/javascript/node_modules');
const fixture = path.join(root,'test/fixtures/native-codecs');
const bindings = JSON.parse(await readFile(path.join(fixture,'bindings-web.json')));
const source = await readFile(path.join(fixture,'domain.lawspec'),'utf8');
const original = await readFile(path.join(fixture,'codec_hooks.ts'),'utf8');
for (const target of ['javascript','typescript']) for (const minify of [false,true])
for (const machineBits of [32,64]) {
  const ts = target === 'typescript';
  const ext = ts ? 'ts' : 'mjs';
  const sourceDir = machineBits === 32 ? 'library/native' : 'src';
  const testDir = machineBits === 32 ? 'checks/properties' : 'test';
  const relative = path.relative(testDir,sourceDir).split(path.sep).join('/');
  const output = path.join(root,'.artifacts/web-native-codec-hooks',
    `${target}-${machineBits}-${minify}${bindings.generators ? '-generators' : ''}`);
  const request = {
    schemaVersion:4,method:'planGeneration',target,minify,machineBits,sourceDir,testDir,
    sources:[{path:'codecs.lawspec',content:source}],nativeBindings:bindings,generation:{exhaustiveLimit:1},
  };
  const result = JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),
    encoding:'utf8',maxBuffer:32*1024*1024}));
  assert.deepEqual(result.diagnostics,[]);
  assert.deepEqual(await wasm.planGeneration(request),result,'Web native/WASM binding parity');
  const adapter = result.files.find(file=>file.path.endsWith(`native/codecs.${ext}`));
  assert.equal(adapter.ownership,'generated');
  for (const file of result.files) {
    const destination = path.join(output,file.path);
    await mkdir(path.dirname(destination),{recursive:true});
    await writeFile(destination,file.content);
  }
  const prepare = content => ts ? content : typescript.transpileModule(content,{
    compilerOptions:{target:typescript.ScriptTarget.ES2022,module:typescript.ModuleKind.ESNext},
  }).outputText.replaceAll('.js\'', '.mjs\'');
  await writeFile(path.join(output,sourceDir,`codec_domain.${ext}`),
    prepare(await readFile(path.join(fixture,'codec_domain.ts'),'utf8')));
  const domain = prepare(original);
  const domainPath = path.join(output,sourceDir,`codec_hooks.${ext}`);
  await writeFile(domainPath,domain);
  if (bindings.generators) await writeFile(path.join(output,testDir,`codec_generators.${ext}`),
    prepare((await readFile(path.join(fixture,'codec_generators.ts'),'utf8'))
      .replaceAll('../src/',relative+'/')));
  await writeFile(path.join(output,'package.json'),'{"type":"module"}\n');
  await symlink(dependencies,path.join(output,'node_modules')).catch(error=>{
    if (error.code !== 'EEXIST') throw error;
  });
  await writeFile(path.join(output,'tsconfig.json'),JSON.stringify({compilerOptions:{
    target:'ES2022',module:'NodeNext',strict:true,skipLibCheck:true,rootDir:'.',outDir:'dist',
  },include:[`${sourceDir}/**/*.ts`,`${testDir}/**/*.ts`]}));
  const testPaths = result.files.filter(file=>file.path.includes('.lawspec.test.'))
    .map(file=>ts ? path.join('dist',file.path.replace(/\.ts$/,'.js')) : file.path);
  const run = async label => {
    if (ts) execFileSync(process.execPath,[tsc,'-p',output],{encoding:'utf8'});
    const check = spawnSync(process.execPath,['--test',...testPaths],{
      cwd:output,encoding:'utf8',maxBuffer:32*1024*1024});
    const log = (check.stdout ?? '')+(check.stderr ?? '');
    await writeFile(path.join(output,`${label}.log`),log);
    return {...check,log};
  };
  if (ts) {
    await writeFile(path.join(output,'tsconfig.source.json'),JSON.stringify({compilerOptions:{
      target:'ES2022',module:'NodeNext',strict:true,skipLibCheck:true,noEmit:true,types:[],
    },include:[`${sourceDir}/**/*.ts`]}));
    execFileSync(process.execPath,[tsc,'-p',path.join(output,'tsconfig.source.json')],{encoding:'utf8'});
  }
  const correct = await run('correct');
  assert.equal(correct.status,0,correct.log);
  const env={...process.env,
    LAWSPEC_DATA_DIR:path.join(output,ts ? 'dist' : '',sourceDir),
    LAWSPEC_STRATEGIES_DIR:path.join(output,ts ? 'dist' : '',testDir),
    LAWSPEC_DATA_EXTENSION:ts ? 'js' : 'mjs',
    LAWSPEC_FAST_CHECK:path.join(dependencies,'fast-check/lib/fast-check.js'),
  };
  for (const name of ['WebCodecBindingsCheck.mjs','WebBoundCodecGeneratorCheck.mjs']) {
    const check=spawnSync(process.execPath,['--test',path.join(root,'test/runtime',name)],{encoding:'utf8',env});
    await writeFile(path.join(output,name+'.log'),check.stdout+check.stderr);
    assert.equal(check.status,0,check.stdout+check.stderr);
  }
  try {
    for (const [label,before,after,expected] of [
      ['decoding-error','return new domain.Positive(value.value);','throw new Error("custom decoding failed");',/Positive toNative:.*custom decoding failed/],
      ['encoding-error','return new data.PositivePositive(value.unpack());','throw new Error("custom encoding failed");',/Positive fromNative:.*custom encoding failed/],
      ['invalid-result','new data.PositivePositive(value.unpack())','new data.PositivePositive(0)',/field refinement 1 failed/],
      ['collapsed-tail','ended ? new data.Just(new data.ChainStop<A>()) : new data.Nothing()','new data.Just(new data.ChainStop<A>())',/flattened recursive representation/],
    ]) {
      assert.ok(original.includes(before));
      await writeFile(domainPath,prepare(original.replace(before,after)));
      const failed=await run(label);
      assert.notEqual(failed.status,0,failed.log);
      assert.match(failed.log,expected);
    }
  } finally { await writeFile(domainPath,domain); }
  const generatorPath=path.join(output,testDir,`codec_generators.${ext}`);
  const generator=await readFile(generatorPath,'utf8');
  try {
    await writeFile(generatorPath,generator.replace('min: 1','min: 0').replace('max: 100','max: 0')
      .replace('min:1','min:0').replace('max:100','max:0'));
    const failed=await run('invalid-generator');
    assert.notEqual(failed.status,0,failed.log);
    assert.match(failed.log,/native generator.*Positive.*field refinement 1 failed/);
  } finally { await writeFile(generatorPath,generator); }
  console.log(`${target} codec hooks: profiles, private storage, recursive variants, native shrinking and rejected mutants; ${machineBits}, compact=${minify}`);
}
