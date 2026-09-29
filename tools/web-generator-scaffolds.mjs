// Compile every factory signature and verify that TypeScript keeps native types.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile, symlink, rm} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';
const root=path.resolve(import.meta.dirname,'..');
const compiler=process.env.LAWSPEC_CORE;
assert.ok(compiler,'Set LAWSPEC_CORE');
const wasm=await createCompiler();
const tsc=path.join(root,'.artifacts/web-data-deps/typescript/bin/tsc');
const dependencies=path.join(root,'.artifacts/lists/javascript/node_modules');
const scalars=['Bool',...['Int','UInt'].flatMap(prefix=>[8,16,32,64].map(width=>prefix+width)),
  'IntSize','UIntSize','UIntPtr','Integer','BigInt','BigUInt','Decimal','Rational',
  'Float32','Float64','Complex64','Complex128','Char','CodePoint','CodeUnit16',
  'Text','CodePointText','Utf16Text','Bytes','Symbol','Unit','Null','Undefined'];
const builtins=['List','Maybe','Either','Nullable','Optional'];
const source=`unit catalog
type Wrap (a :: Type) is Wrap value :: a end
type Box (a :: Type) is Box value :: a end
`;
const generators=[...scalars,...builtins].map(type=>({type,factory:['factories','catalog',`make${type}`],stub:true}));
generators.push({type:'catalog::type::Wrap',factory:['factories','catalog','wrap'],stub:true},
  {type:'catalog::type::Box',factory:['factories','catalog','box'],stub:true});
const nativeBindings={generators,types:[{type:'catalog::type::Box',native:['application_types','NativeBox'],
  constructors:[{constructor:'Box',native:['application_types','NativeBox'],style:'record',
    fields:[{field:'value',native:'value'}]}]}]};
for(const target of ['javascript','typescript']) for(const machineBits of [32,64]) for(const minify of [false,true]) {
  const ts=target==='typescript', ext=ts?'ts':'mjs';
  const directory=path.join(root,'.artifacts/web-generator-scaffolds',`${target}-${machineBits}-${minify}`);
  const sourceDir='library/model', testDir='checks/native';
  await rm(directory,{recursive:true,force:true});
  await mkdir(directory,{recursive:true});
  const request={schemaVersion:4,method:'planGeneration',target,machineBits,minify,sourceDir,testDir,
    sources:[{path:'catalog.lawspec',content:source}],nativeBindings};
  const result=JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),encoding:'utf8',maxBuffer:32*1024*1024}));
  assert.deepEqual(result.diagnostics,[]);
  assert.deepEqual(await wasm.planGeneration(request),result);
  for(const file of result.files) {
    const destination=path.join(directory,file.path);
    await mkdir(path.dirname(destination),{recursive:true});
    await writeFile(destination,file.content);
  }
  await symlink(dependencies,path.join(directory,'node_modules'));
  await writeFile(path.join(directory,'package.json'),'{"type":"module"}\n');
  await writeFile(path.join(directory,sourceDir,`application_types.${ext}`),ts ?
    'export class NativeBox<T> { value: T; constructor(fields: {value: T}) { this.value = fields.value; } }\n' :
    'export class NativeBox { constructor(fields) { this.value = fields.value; } }\n');
  if(ts) {
    const checks=`import type * as fc from 'fast-check';
import * as factories from './factories/catalog.js';
import type {NativeBox} from '../../library/model/application_types.js';
import * as data from '../../library/model/lawspec_data.js';
export function check(child: fc.Arbitrary<number>): void {
  const box: fc.Arbitrary<NativeBox<number>> = factories.box(child);
  const wrap: fc.Arbitrary<data.Wrap<number>> = factories.wrap(child);
  const list: fc.Arbitrary<Array<number>> = factories.makeList(child);
  void box; void wrap; void list;
}
`;
    const checkPath=path.join(directory,testDir,'signature-check.ts');
    await writeFile(checkPath,checks);
    await writeFile(path.join(directory,'tsconfig.json'),JSON.stringify({compilerOptions:{
      target:'ES2022',module:'NodeNext',strict:true,skipLibCheck:true,rootDir:'.',outDir:'dist',
    },include:[`${sourceDir}/**/*.ts`,`${testDir}/**/*.ts`]}));
    execFileSync(process.execPath,[tsc,'-p',directory],{encoding:'utf8'});
    await writeFile(checkPath,checks+"const wrong: import('fast-check').Arbitrary<string> = factories.makeInt8();\n");
    const rejected=spawnSync(process.execPath,[tsc,'-p',directory,'--noEmit'],{encoding:'utf8'});
    assert.notEqual(rejected.status,0);
    assert.match(rejected.stdout,/TS2322/);
    await writeFile(checkPath,checks);
  }
  const modulePath=ts?`./dist/${testDir}/factories/catalog.js`:`./${testDir}/factories/catalog.mjs`;
  execFileSync(process.execPath,['--input-type=module','-e',`
import assert from 'node:assert/strict';
import * as fc from 'fast-check';
import * as factories from ${JSON.stringify(modulePath)};
for (const name of ['makeInt8','makeDecimal','makeUnit','makeCodePointText']) {
  assert.throws(() => factories[name](), /Implement generator for/);
}
for (const name of ['makeList','makeMaybe','makeEither','wrap','box']) {
  assert.throws(() => factories[name](fc.integer(), fc.string()), /Implement generator for/);
}
`],{cwd:directory,encoding:'utf8'});
  console.log(`${target} ${machineBits}, minify=${minify}: all signatures compile and unimplemented factories fail explicitly`);
}
