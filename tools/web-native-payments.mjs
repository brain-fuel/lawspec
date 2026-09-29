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
const fixture = path.join(root,'test/fixtures/native-payments');
const bindings = JSON.parse(await readFile(path.join(fixture,'bindings-web.json')));
bindings.functions.push({declaration:'example.payments::mirror',
  native:['payments_domain','restore']});
const scaffold = process.env.LAWSPEC_GENERATOR_STUBS === '1';
if (scaffold || process.env.LAWSPEC_NATIVE_GENERATORS === '1') bindings.generators = [{
  type:'example.payments::type::Money',factory:['lawspec_generators','prices'],
}];
if (scaffold) {
  bindings.generators[0].factory=['factories','lawspec_generators','prices'];
  bindings.generators.push({type:'List',factory:['factories','lawspec_generators','lists']});
  for(const binding of bindings.generators) binding.stub=true;
}
const source = await readFile(path.join(root,'examples/specs/payments.lawspec'),'utf8') + `
mirror :: Payment -> Payment
law \`two adapters share one native function\` is
  definition is \`for all\` (x :: Payment) . mirror x = x end
end
`;
const original = await readFile(path.join(fixture,'domain.ts'),'utf8');
for (const target of ['javascript','typescript']) for (const minify of [false,true])
for (const machineBits of [32,64]) {
  const ts = target === 'typescript';
  const ext = ts ? 'ts' : 'mjs';
  const sourceDir = machineBits === 32 ? 'library/native' : 'src';
  const testDir = machineBits === 32 ? 'checks/properties' : 'test';
  const relative = path.relative(testDir,sourceDir).split(path.sep).join('/');
  const output = path.join(root,'.artifacts/web-native-payments',
    `${target}-${machineBits}-${minify}${bindings.generators ? '-generators' : ''}${scaffold ? '-stubs' : ''}`);
  const request = {
    schemaVersion:4,method:'planGeneration',target,minify,machineBits,sourceDir,testDir,
    sources:[{path:'payments.lawspec',content:source}],nativeBindings:bindings,
  };
  const result = JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),
    encoding:'utf8',maxBuffer:32*1024*1024}));
  assert.deepEqual(result.diagnostics,[]);
  assert.deepEqual(await wasm.planGeneration(request),result,'Web native/WASM binding parity');
  const adapter = result.files.find(file=>file.path.endsWith(`example/payments.${ext}`));
  assert.equal(adapter.ownership,'generated');
  for (const file of result.files) {
    const destination = path.join(output,file.path);
    await mkdir(path.dirname(destination),{recursive:true});
    await writeFile(destination,file.content);
  }
  const prepare = content => ts ? content : typescript.transpileModule(content,{
    compilerOptions:{target:typescript.ScriptTarget.ES2022,module:typescript.ModuleKind.ESNext},
  }).outputText.replaceAll('.js\'', '.mjs\'');
  const domain = prepare(original);
  const domainPath = path.join(output,sourceDir,`payments_domain.${ext}`);
  await writeFile(domainPath,domain);
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
  if (scaffold) {
    const stub=result.files.find(file=>file.path===`${testDir}/factories/lawspec_generators.${ext}`);
    assert.equal(stub.ownership,'user');
    assert.equal(stub.placement,'test');
    const missing=await run('unimplemented');
    assert.notEqual(missing.status,0,missing.log);
    assert.match(missing.log,/Implement generator for/);
    console.log(`${target} ${machineBits}, minify=${minify}: typed scaffolds compile and fail explicitly`);
  }
  if (bindings.generators) {
    const moduleDir=scaffold ? path.posix.join(testDir,'factories') : testDir;
    const sourceRelative=path.relative(moduleDir,sourceDir).split(path.sep).join('/');
    const implementation=(await readFile(path.join(fixture,'generators.ts'),'utf8'))
      .replaceAll('../src/',sourceRelative+'/') + (scaffold ? `
export let listFactories = 0;

export function lists<T>(argument_0: fc.Arbitrary<T>): fc.Arbitrary<Array<T>> {
  listFactories += 1;
  return fc.array(argument_0, {maxLength: 8});
}
` : '');
    await writeFile(path.join(output,moduleDir,`lawspec_generators.${ext}`),prepare(implementation));
  }
  const correct = await run('correct');
  assert.equal(correct.status,0,correct.log);
  execFileSync(process.execPath,['--test',path.join(root,'test/runtime/WebNativeBindingsCheck.mjs'),
    ...(bindings.generators ? [path.join(root,'test/runtime/WebBoundGeneratorCheck.mjs')] : []),
    ...(scaffold ? [path.join(root,'test/runtime/WebGeneratorScaffoldCheck.mjs')] : [])],{
    encoding:'utf8',env:{...process.env,
      LAWSPEC_DATA_DIR:path.join(output,ts ? 'dist' : '',sourceDir),
      LAWSPEC_STRATEGIES_DIR:path.join(output,ts ? 'dist' : '',testDir),
      LAWSPEC_DATA_EXTENSION:ts ? 'js' : 'mjs',
      LAWSPEC_FAST_CHECK:path.join(dependencies,'fast-check/lib/fast-check.js'),
    },
  });
  console.log(`${target} ${machineBits}, minify=${minify}: application types pass`);
  if (machineBits === 64 && !minify) try {
    for (const [name,before,after] of [
      ['wrong-fee','new ls.Decimal(2n, -1n)','new ls.Decimal(3n, -1n)'],
      ['currency-loss','unit: price.unit','unit: new Dollars()'],
      ['absence-loss','return payments;','return [];'],
    ]) {
      assert.ok(domain.includes(before));
      await writeFile(domainPath,domain.replace(before,after));
      const broken = await run(name);
      assert.notEqual(broken.status,0,broken.log);
      assert.match(broken.log,/AssertionError|ERR_ASSERTION/);
      console.log(`${target}: ${name} rejected by an executable law`);
    }
  } finally { await writeFile(domainPath,domain); }
}
