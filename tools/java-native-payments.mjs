// Execute generated Java native codecs against application records and enums.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {templates} from '../npm/templates.mjs';
import {createCompiler} from '../npm/api.mjs';
const root=path.resolve(import.meta.dirname,'..');
const compiler=process.env.LAWSPEC_CORE;
assert.ok(compiler,'Set LAWSPEC_CORE');
const wasm=await createCompiler();
const fixture=path.join(root,'test/fixtures/native-payments');
const nativeBindings=JSON.parse(await readFile(path.join(fixture,'bindings-java.json')));
const shapesFixture=path.join(root,'test/fixtures/native-shapes');
const shapesBindings=JSON.parse((await readFile(path.join(shapesFixture,'bindings-java.json'),'utf8'))
  .replaceAll('native.shapes::','bound.shapes::'));
nativeBindings.types.push(...shapesBindings.types);
nativeBindings.functions.push(...shapesBindings.functions);
const scaffold=process.env.LAWSPEC_GENERATOR_STUBS === '1';
if (scaffold || process.env.LAWSPEC_NATIVE_GENERATORS === '1') nativeBindings.generators = [
  {type:'example.payments::type::Money',factory:['domain','PaymentGenerators','prices']},
  {type:'bound.shapes::type::Box',factory:['domain','PaymentGenerators','boxes']},
  {type:'Int8',factory:['domain','PaymentGenerators','bytes']},
  {type:'bound.shapes::type::Stamp',factory:['domain','PaymentGenerators','seals']},
];
if (scaffold) for(const binding of nativeBindings.generators) binding.stub=true;
const source=await readFile(path.join(root,'examples/specs/payments.lawspec'),'utf8');
const shapes=(await readFile(path.join(root,'test/fixtures/native_shapes.lawspec'),'utf8'))
  .replace('unit native.shapes','unit bound.shapes');
const domain=await readFile(path.join(fixture,'PaymentsDomain.java'),'utf8');
for (const minify of [false,true]) for (const machineBits of [32,64]) {
  const sourceDir=machineBits===32 ? 'library/native' : 'src/main/java';
  const testDir=machineBits===32 ? 'checks/properties' : 'src/test/java';
  const output=path.join(root,'.artifacts/java-native-payments',
    `${machineBits}-${minify}-shapes${nativeBindings.generators ? '-generators' : ''}${scaffold ? '-stubs' : ''}`);
  const request={schemaVersion:4,method:'planGeneration',target:'java',machineBits,minify,
    sourceDir,testDir,sources:[{path:'payments.lawspec',content:source},
      {path:'shapes.lawspec',content:shapes}],nativeBindings,generation:{exhaustiveLimit:1}};
  const result=JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),
    encoding:'utf8',maxBuffer:32*1024*1024}));
  assert.deepEqual(result.diagnostics,[]);
  assert.deepEqual(await wasm.planGeneration(request),result,'Java native/WASM binding parity');
  assert.equal(result.files.find(file=>file.path.endsWith('example/Payments.java')).ownership,'generated');
  if (!minify) for (const file of result.files.filter(file =>
    /(?:LawSpecNativeCodecs|example\/Payments|bound\/Shapes)\.java$/.test(file.path))) {
    for (const [line,content] of file.content.split('\n').entries())
      assert.ok(content.length<=100,`${file.path}:${line+1} exceeds 100 columns`);
  }
  for (const file of result.files) {
    const destination=path.join(output,file.path);
    await mkdir(path.dirname(destination),{recursive:true});
    await writeFile(destination,file.content);
  }
  for (const [name,content] of Object.entries(templates('java'))) {
    const destination=path.join(output,name);
    await mkdir(path.dirname(destination),{recursive:true});
    await writeFile(destination,name==='pom.xml' ? content.replace('<build>',
      `<build><sourceDirectory>${sourceDir}</sourceDirectory><testSourceDirectory>${testDir}</testSourceDirectory>`) : content);
  }
  const domainPath=path.join(output,sourceDir,'domain/PaymentsDomain.java');
  await mkdir(path.dirname(domainPath),{recursive:true});
  await writeFile(domainPath,domain);
  await writeFile(path.join(output,sourceDir,'domain/Shapes.java'),
    await readFile(path.join(shapesFixture,'Shapes.java')));
  const run=async label=>{
    const execution=spawnSync('mvn',['-o','-q','test'],{cwd:output,encoding:'utf8',maxBuffer:32*1024*1024});
    const log=(execution.stdout??'')+(execution.stderr??'');
    await writeFile(path.join(output,`${label}.log`),log);
    return {...execution,log};
  };
  if (scaffold) {
    const stub=result.files.find(file=>file.path===`${testDir}/domain/PaymentGenerators.java`);
    assert.equal(stub.ownership,'user');
    assert.equal(stub.placement,'test');
    execFileSync('mvn',['-o','-q','test-compile'],{cwd:output,encoding:'utf8'});
    const missing=await run('unimplemented');
    assert.notEqual(missing.status,0,missing.log);
    assert.match(missing.log,/Implement generator for/);
    assert.doesNotMatch(missing.log,/COMPILATION ERROR/);
    console.log(`Java ${machineBits}, minify=${minify}: typed scaffolds compile and fail explicitly`);
  }
  if (nativeBindings.generators) for (const [name,packageName] of [
    ['PaymentGenerators.java','domain'],['NativeGeneratorContractsTest.java','bound'],
  ]) {
    const destination=path.join(output,testDir,packageName,name);
    await mkdir(path.dirname(destination),{recursive:true});
    await writeFile(destination,await readFile(path.join(fixture,name)));
  }
  const correct=await run('correct');
  assert.equal(correct.status,0,correct.log);
  console.log(`Java ${machineBits}, minify=${minify}: native records/enums pass`);
  if (machineBits===64 && !minify) try {
    for (const [name,before,after] of [
      ['wrong-fee','new BigDecimal("0.2")','new BigDecimal("0.3")'],
      ['currency-loss','price.unit()','CurrencyCode.Dollars'],
      ['absence-loss','return payments;','return List.of();'],
    ]) {
      assert.ok(domain.includes(before));
      await writeFile(domainPath,domain.replace(before,after));
      const broken=await run(name);
      assert.notEqual(broken.status,0,broken.log);
      assert.match(broken.log,/Failures: [1-9]/);
      assert.doesNotMatch(broken.log,/COMPILATION ERROR/);
      console.log(`Java: ${name} rejected by an executable law`);
    }
  } finally { await writeFile(domainPath,domain); }
  if (machineBits===64 && !minify && nativeBindings.generators) {
    const factoryPath=path.join(output,testDir,'domain/PaymentGenerators.java');
    const factory=await readFile(factoryPath,'utf8');
    const amount='new BigDecimal(BigInteger.valueOf(cents), 2)';
    assert.ok(factory.includes(amount));
    try {
      await writeFile(factoryPath,factory.replace(amount,'null'));
      const invalid=await run('invalid-generator');
      assert.notEqual(invalid.status,0,invalid.log);
      assert.match(invalid.log,/native generator example.payments::type::Money/);
      assert.match(invalid.log,/org\.jetbrains\.jetCheck\.PropertyFalsified/);
      assert.match(invalid.log,/PaymentsLawSpecTest\.law0Property/);
      assert.doesNotMatch(invalid.log,/COMPILATION ERROR/);
      console.log('Java: invalid native generator reaches the property failure');
    } finally { await writeFile(factoryPath,factory); }
  }
}
