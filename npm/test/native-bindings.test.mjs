// Generated from templates/npm/test/native-bindings.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile, mkdtemp, rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createCompiler} from '../api.mjs';
import {planWrites, applyWrites} from '../files.mjs';

const compiler = await createCompiler();
const sources = [{path: 'payments.lawspec', content:
  await readFile(new URL('../examples/specs/payments.lawspec', import.meta.url), 'utf8')}];
const nativeBindings = JSON.parse(await readFile(
  new URL('../../test/fixtures/native-payments/bindings.json', import.meta.url), 'utf8'));

test('adopting a native binding cannot overwrite an existing user-owned adapter', async () => {
  const before = await compiler.planGeneration({sources, target: 'rust'});
  const after = await compiler.planGeneration({sources, nativeBindings, target: 'rust'});
  const directory = await mkdtemp(path.join(os.tmpdir(), 'lawspec-native-ownership-'));
  try {
    const plan = await planWrites(directory, before.files);
    await applyWrites([plan]);
    await assert.rejects(planWrites(directory, after.files), /Refusing to overwrite unowned or edited/);
  } finally {
    await rm(directory, {recursive: true, force: true});
  }
});

test('Python generator scaffolds group factories and preserve implementations across signature changes', async () => {
  const {writeFile} = await import('node:fs/promises');
  const directory = await mkdtemp(path.join(os.tmpdir(), 'lawspec-generator-stubs-'));
  const sources = [{path:'stub.lawspec', content:'unit stub'}];
  const factory = ['application_generators','collections','values'];
  const generate = async (type, minify=false, testDir='checks/native') => {
    const result = await compiler.planGeneration({sources, target:'python', testDir, minify,
      nativeBindings:{generators:[{type,factory,stub:true},
        {type:'Bool',factory:['application_generators','collections','flags'],stub:true}]}});
    assert.deepEqual(result.diagnostics,[]);
    return result.files;
  };
  try {
    const files = await generate('List');
    const stub = files.find(file=>file.path==='checks/native/application_generators/collections.py');
    assert.equal(stub.ownership,'user');
    assert.equal(stub.placement,'test');
    assert.match(stub.content,/def values\(/);
    assert.match(stub.content,/argument_0: _strategies.SearchStrategy/);
    assert.match(stub.content,/def flags\(/);
    assert.match(stub.content,/NotImplementedError/);
    await applyWrites([await planWrites(directory,files)]);
    const implementation = '# my factory, including its original shrinking\n';
    await writeFile(path.join(directory,stub.path),implementation);
    const compact = await generate('List',true);
    const unchanged = await planWrites(directory,compact);
    assert.deepEqual(unchanged.adapterUpdates,[],'format changes do not change the scaffold contract');
    await applyWrites([unchanged]);
    const changed = await planWrites(directory,await generate('Either',true));
    assert.equal(changed.adapterUpdates.length,1);
    assert.match(changed.adapterUpdates[0].requiredAdapter,/argument_1: _strategies.SearchStrategy/);
    await applyWrites([changed]);
    assert.equal(await readFile(path.join(directory,stub.path),'utf8'),implementation);
    const moved = await generate('Either',true,'relocated');
    await applyWrites([await planWrites(directory,moved)]);
    assert.equal(await readFile(path.join(directory,stub.path),'utf8'),implementation);
    assert.match(await readFile(path.join(directory,'relocated/application_generators/collections.py'),'utf8'),/def values/);
  } finally {
    await rm(directory,{recursive:true,force:true});
  }
});

test('Rust factory scaffolds retain native signatures, nested modules and ownership', async () => {
  const {writeFile} = await import('node:fs/promises');
  const directory=await mkdtemp(path.join(os.tmpdir(),'lawspec-rust-scaffolds-'));
  const sources=[{path:'stub.lawspec',content:'unit stub'}];
  const plan=async(type,minify=false,testDir='checks/native',stub=true)=>{
    const result=await compiler.planGeneration({sources,target:'rust',testDir,minify,
      nativeBindings:{rustCrate:'application',generators:[
        {type,factory:['crate','factories','collections','values'],stub},
        {type:'Int8',factory:['factories','integers'],stub},
      ]}});
    assert.deepEqual(result.diagnostics,[]);
    return result.files;
  };
  try {
    const files=await plan('List');
    const stub=files.find(file=>file.path==='checks/native/support/factories.rs');
    assert.equal(stub.ownership,'user');
    assert.equal(stub.placement,'test');
    assert.match(stub.content,/pub mod collections/);
    assert.match(stub.content,/BoxedStrategy<T0>/);
    assert.match(stub.content,/BoxedStrategy<Vec<T0>>/);
    assert.match(stub.content,/BoxedStrategy<i8>/);
    assert.match(files.find(file=>file.path.endsWith('_lawspec.rs')).content,/mod factories;/);
    await applyWrites([await planWrites(directory,files)]);
    const implementation='// application-owned Proptest factory\n';
    await writeFile(path.join(directory,stub.path),implementation);
    const compact=await planWrites(directory,await plan('List',true));
    assert.deepEqual(compact.adapterUpdates,[]);
    await applyWrites([compact]);
    const update=await planWrites(directory,await plan('Either',true));
    assert.equal(update.adapterUpdates.length,1);
    assert.match(update.adapterUpdates[0].requiredAdapter,/application::lawspec_runtime::Either<T0, T1>/);
    await applyWrites([update]);
    assert.equal(await readFile(path.join(directory,stub.path),'utf8'),implementation);
    const importOnly=await plan('Either',false,'checks/native',false);
    assert.ok(!importOnly.some(file=>file.path===stub.path));
    assert.match(importOnly.find(file=>file.path.endsWith('_lawspec.rs')).content,/mod factories;/);
    await applyWrites([await planWrites(directory,importOnly)]);
    assert.equal(await readFile(path.join(directory,stub.path),'utf8'),implementation);
    await applyWrites([await planWrites(directory,await plan('Either',true,'relocated'))]);
    assert.equal(await readFile(path.join(directory,stub.path),'utf8'),implementation);
    assert.match(await readFile(path.join(directory,'relocated/support/factories.rs'),'utf8'),/pub mod collections/);
  } finally {await rm(directory,{recursive:true,force:true});}
});

for (const target of ['javascript','typescript']) {
  test(`${target}: nested native factory scaffolds preserve implementations and follow custom layouts`,async()=>{
    const {writeFile}=await import('node:fs/promises');
    const directory=await mkdtemp(path.join(os.tmpdir(),`lawspec-${target}-scaffolds-`));
    const extension=target==='typescript'?'ts':'mjs';
    const sources=[{path:'stub.lawspec',content:'unit stub'}];
    const plan=async(type,minify=false,testDir='checks/native')=>{
      const result=await compiler.planGeneration({sources,target,minify,testDir,sourceDir:'library/domain',
        nativeBindings:{generators:[{type,factory:['factories','collections','values'],stub:true},
          {type:'Int8',factory:['factories','collections','bytes'],stub:true}]}});
      assert.deepEqual(result.diagnostics,[]);
      return result.files;
    };
    try {
      const files=await plan('List');
      const stub=files.find(file=>file.path===`checks/native/factories/collections.${extension}`);
      assert.equal(stub.ownership,'user');
      assert.equal(stub.placement,'test');
      assert.match(stub.content,/export function values/);
      assert.match(stub.content,/export function bytes/);
      if(target==='typescript') {
        assert.match(stub.content,/Arbitrary<Array<T0>>/);
        assert.match(stub.content,/from '\.\.\/\.\.\/\.\.\/library\/domain\/lawspec_data.js'/);
      }
      await applyWrites([await planWrites(directory,files)]);
      const implementation='// application-owned fast-check arbitraries\n';
      await writeFile(path.join(directory,stub.path),implementation);
      const unchanged=await planWrites(directory,await plan('List',true));
      assert.deepEqual(unchanged.adapterUpdates,[]);
      await applyWrites([unchanged]);
      const changed=await planWrites(directory,await plan('Either',true));
      assert.equal(changed.adapterUpdates.length,1);
      assert.match(changed.adapterUpdates[0].requiredAdapter,/argument_1/);
      await applyWrites([changed]);
      assert.equal(await readFile(path.join(directory,stub.path),'utf8'),implementation);
      await applyWrites([await planWrites(directory,await plan('Either',true,'relocated'))]);
      assert.equal(await readFile(path.join(directory,stub.path),'utf8'),implementation);
      assert.match(await readFile(path.join(directory,`relocated/factories/collections.${extension}`),'utf8'),/argument_1/);
    } finally {await rm(directory,{recursive:true,force:true});}
  });
  test(`${target}: scaffold conflicts are rejected before writing files`,async()=>{
    for(const factories of [
      [['lawspec_native_generators','values']],
      [['factories','globalThis']],
      [['factories','values'],['Factories','other']],
    ]) {
      const result=await compiler.planGeneration({target,sources:[{path:'stub.lawspec',content:'unit stub'}],
        nativeBindings:{generators:factories.map((factory,index)=>({type:index?'Int16':'Int8',factory,stub:true}))}});
      assert.equal(result.diagnostics[0].code,'native-binding');
      assert.match(result.diagnostics[0].message,/conflict/);
    }
  });
}

for(const target of ['python','javascript','typescript','java','kotlin']) {
  test(`${target}: changing a native result class reports a scaffold update`,async()=>{
    const directory=await mkdtemp(path.join(os.tmpdir(),`lawspec-${target}-result-update-`));
    const plan=async name=>{
      const result=await compiler.planGeneration({target,
        sources:[{path:'scope.lawspec',content:'unit scope\ntype Money is Money amount :: Int8 end'}],
        nativeBindings:{types:[{type:'scope::type::Money',native:['domain',name],constructors:[
          {constructor:'Money',native:['domain',name],style:'record',fields:[{field:'amount',native:'amount'}]},
        ]}],generators:[{type:'scope::type::Money',factory:['java','kotlin'].includes(target)?['application','Factories','prices']:['factories','prices'],stub:true}]}});
      assert.deepEqual(result.diagnostics,[]);
      return result.files;
    };
    try {
      await applyWrites([await planWrites(directory,await plan('Price'))]);
      const update=await planWrites(directory,await plan('NewPrice'));
      assert.equal(update.adapterUpdates.length,1);
      assert.match(update.adapterUpdates[0].requiredAdapter,/domain\.NewPrice/);
    } finally {await rm(directory,{recursive:true,force:true});}
  });
}

test('Java generator scaffolds group typed factories and preserve edited implementations',async()=>{
  const {writeFile}=await import('node:fs/promises');
  const directory=await mkdtemp(path.join(os.tmpdir(),'lawspec-java-scaffolds-'));
  const plan=async(type,minify=false,testDir='checks/native')=>{
    const result=await compiler.planGeneration({target:'java',minify,testDir,
      sources:[{path:'stub.lawspec',content:'unit stub'}],nativeBindings:{generators:[
        {type,factory:['application','Factories','values'],stub:true},
        {type:'Int8',factory:['application','Factories','bytes'],stub:true},
      ]}});
    assert.deepEqual(result.diagnostics,[]);
    return result.files;
  };
  try {
    const files=await plan('List');
    const stub=files.find(file=>file.path==='checks/native/application/Factories.java');
    assert.equal(stub.ownership,'user');
    assert.equal(stub.placement,'test');
    assert.match(stub.content.replace(/\s+/g,''),/Generator<java.util.List<T0>>/);
    assert.match(stub.content,/Generator<java.lang.Byte>/);
    await applyWrites([await planWrites(directory,files)]);
    const implementation='// native JetCheck factory implementation\n';
    await writeFile(path.join(directory,stub.path),implementation);
    const compact=await planWrites(directory,await plan('List',true));
    assert.deepEqual(compact.adapterUpdates,[]);
    await applyWrites([compact]);
    const changed=await planWrites(directory,await plan('Either',true));
    assert.equal(changed.adapterUpdates.length,1);
    assert.match(changed.adapterUpdates[0].requiredAdapter,/argument1/);
    await applyWrites([changed]);
    await applyWrites([await planWrites(directory,await plan('Either',true,'relocated'))]);
    assert.equal(await readFile(path.join(directory,stub.path),'utf8'),implementation);
    assert.match(await readFile(path.join(directory,'relocated/application/Factories.java'),'utf8'),/argument1/);
  } finally {await rm(directory,{recursive:true,force:true});}
});

test('Kotlin scaffolds group native Arb factories and preserve implementations across signature changes',async()=>{
  const {writeFile}=await import('node:fs/promises');
  const directory=await mkdtemp(path.join(os.tmpdir(),'lawspec-kotlin-scaffolds-'));
  const plan=async(type,minify=false,testDir='checks/native')=>{
    const result=await compiler.planGeneration({target:'kotlin',minify,testDir,
      sources:[{path:'stub.lawspec',content:'unit stub'}],nativeBindings:{generators:[
        {type,factory:['application','Factories','values'],stub:true},
        {type:'Int8',factory:['application','Factories','bytes'],stub:true},
      ]}});
    assert.deepEqual(result.diagnostics,[]);
    return result.files;
  };
  try {
    const files=await plan('List');
    const stub=files.find(file=>file.path==='checks/native/application/Factories.kt');
    assert.equal(stub.ownership,'user');
    assert.equal(stub.placement,'test');
    assert.match(stub.content.replace(/\s+/g,''),/Arb<kotlin.collections.List<T0>>/);
    assert.match(stub.content,/Arb<kotlin.Byte>/);
    await applyWrites([await planWrites(directory,files)]);
    const implementation='// application-owned Kotest factories\n';
    await writeFile(path.join(directory,stub.path),implementation);
    const compact=await planWrites(directory,await plan('List',true));
    assert.deepEqual(compact.adapterUpdates,[]);
    await applyWrites([compact]);
    const changed=await planWrites(directory,await plan('Either',true));
    assert.equal(changed.adapterUpdates.length,1);
    assert.match(changed.adapterUpdates[0].requiredAdapter,/argument1/);
    await applyWrites([changed]);
    await applyWrites([await planWrites(directory,await plan('Either',true,'relocated'))]);
    assert.equal(await readFile(path.join(directory,stub.path),'utf8'),implementation);
    assert.match(await readFile(path.join(directory,'relocated/application/Factories.kt'),'utf8'),/argument1/);
  } finally {await rm(directory,{recursive:true,force:true});}
});

test('Go scaffolds preserve generic Rapid factories through layouts and signature changes',async()=>{
  const {writeFile}=await import('node:fs/promises');
  const directory=await mkdtemp(path.join(os.tmpdir(),'lawspec-go-scaffolds-'));
  const plan=async(type,minify=false,sourceDir='checks/native')=>{
    const applied=type==='List'?'List Int8':'Either Int8 Text';
    const result=await compiler.planGeneration({target:'go',minify,sourceDir,testDir:sourceDir,
      sources:[{path:'stub.lawspec',content:`unit stub\nlaw \`identity\` is definition is \`for all\` (x :: ${applied}) . x = x end end`}],
      nativeBindings:{generators:[{type,factory:['NativeValues'],stub:true},{type:'Int8',factory:['NativeBytes'],stub:true}]}});
    assert.deepEqual(result.diagnostics,[]);
    return result.files;
  };
  try {
    const files=await plan('List');
    const stub=files.find(file=>file.path==='checks/native/stub/native_generators_test.go');
    assert.equal(stub.ownership,'user');
    assert.equal(stub.placement,'test');
    assert.match(stub.content,/NativeValues\[T0 any\]/);
    assert.match(stub.content,/\*rapid.Generator\[\[\]T0\]/);
    await applyWrites([await planWrites(directory,files)]);
    const implementation='package stub\n// application-owned Rapid factories\n';
    await writeFile(path.join(directory,stub.path),implementation);
    const compact=await planWrites(directory,await plan('List',true));
    assert.deepEqual(compact.adapterUpdates,[]);
    await applyWrites([compact]);
    const changed=await planWrites(directory,await plan('Either',true));
    assert.equal(changed.adapterUpdates.length,1);
    assert.match(changed.adapterUpdates[0].requiredAdapter,/argument1/);
    await applyWrites([changed]);
    await applyWrites([await planWrites(directory,await plan('Either',true,'relocated'))]);
    assert.equal(await readFile(path.join(directory,stub.path),'utf8'),implementation);
    assert.match(await readFile(path.join(directory,'relocated/stub/native_generators_test.go'),'utf8'),/argument1/);
  } finally {await rm(directory,{recursive:true,force:true});}
});

test('Go native result class changes update the user-owned factory contract',async()=>{
  const directory=await mkdtemp(path.join(os.tmpdir(),'lawspec-go-native-result-'));
  const plan=async name=>{
    const result=await compiler.planGeneration({target:'go',sources:[{path:'scope.lawspec',content:
      'unit scope\ntype Money is Money amount :: Int8 end\nlaw `identity` is definition is `for all` (x :: Money) . x = x end end'}],
      nativeBindings:{goImports:[{alias:'domain',path:'example.com/domain'}],types:[
        {type:'scope::type::Money',native:['domain',name],constructors:[{constructor:'Money',native:['domain',name],
          style:'record',fields:[{field:'amount',native:'Amount'}]}]},
      ],generators:[{type:'scope::type::Money',factory:['NativePrices'],stub:true}]}});
    assert.deepEqual(result.diagnostics,[]);
    return result.files;
  };
  try {
    await applyWrites([await planWrites(directory,await plan('Price'))]);
    const update=await planWrites(directory,await plan('NewPrice'));
    assert.equal(update.adapterUpdates.length,1);
    assert.match(update.adapterUpdates[0].requiredAdapter,/lawSpecImport0.NewPrice/);
  } finally {await rm(directory,{recursive:true,force:true});}
});

test('Haskell scaffolds preserve typed generic factories and user implementations',async()=>{
  const {writeFile}=await import('node:fs/promises');
  const directory=await mkdtemp(path.join(os.tmpdir(),'lawspec-haskell-scaffolds-'));
  const plan=async(type,minify=false,testDir='checks/native')=>{
    const result=await compiler.planGeneration({target:'haskell',minify,sourceDir:'library/native',testDir,
      sources:[{path:'stub.lawspec',content:'unit stub'}],nativeBindings:{generators:[
        {type,factory:['Application','Generators','values'],stub:true},
        {type:'Int8',factory:['Application','Generators','bytes'],stub:true}]}});
    assert.deepEqual(result.diagnostics,[]);
    return result.files;
  };
  try {
    const files=await plan('List');
    const stub=files.find(file=>file.path==='checks/native/Application/Generators.hs');
    assert.equal(stub.ownership,'user');
    assert.equal(stub.placement,'test');
    assert.match(stub.content,/values :: H.Gen a0 -> H.Gen \[a0\]/);
    assert.match(stub.content,/bytes :: H.Gen I.Int8/);
    await applyWrites([await planWrites(directory,files)]);
    const implementation='module Application.Generators where\n-- User implementation\n';
    await writeFile(path.join(directory,stub.path),implementation);
    const compact=await planWrites(directory,await plan('List',true));
    assert.deepEqual(compact.adapterUpdates,[]);
    await applyWrites([compact]);
    const changed=await planWrites(directory,await plan('Either',true));
    assert.equal(changed.adapterUpdates.length,1);
    assert.match(changed.adapterUpdates[0].requiredAdapter,/H.Gen a1/);
    await applyWrites([changed]);
    await applyWrites([await planWrites(directory,await plan('Either',true,'relocated'))]);
    assert.equal(await readFile(path.join(directory,stub.path),'utf8'),implementation);
    assert.match(await readFile(path.join(directory,'relocated/Application/Generators.hs'),'utf8'),/H.Gen a1/);
  } finally {await rm(directory,{recursive:true,force:true});}
});

test('Haskell native class changes update the generator signature',async()=>{
  const directory=await mkdtemp(path.join(os.tmpdir(),'lawspec-haskell-native-result-'));
  const plan=async name=>{
    const result=await compiler.planGeneration({target:'haskell',sources:[{path:'stub.lawspec',content:
      'unit stub\ntype Money is Money amount :: Int8 end'}],nativeBindings:{types:[
        {type:'stub::type::Money',native:['Domain',name],constructors:[{constructor:'Money',native:['Domain',name],
          style:'record',fields:[{field:'amount',native:'amount'}]}]}],
      generators:[{type:'stub::type::Money',factory:['Factories','prices'],stub:true}]}});
    assert.deepEqual(result.diagnostics,[]);
    return result.files;
  };
  try {
    await applyWrites([await planWrites(directory,await plan('Price'))]);
    const update=await planWrites(directory,await plan('NewPrice'));
    assert.equal(update.adapterUpdates.length,1);
    assert.match(update.adapterUpdates[0].requiredAdapter,/NativeModule0.NewPrice/);
  } finally {await rm(directory,{recursive:true,force:true});}
});
