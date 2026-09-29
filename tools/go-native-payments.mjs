import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile, rm} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const scaffold = process.env.LAWSPEC_GENERATOR_STUBS === '1';
const nativeGenerators = scaffold || process.env.LAWSPEC_NATIVE_GENERATORS === '1';
assert.ok(compiler, 'Set LAWSPEC_CORE');
const {createCompiler} = await import('../npm/api.mjs');
const wasm = await createCompiler();
const read = file => readFile(path.join(root, file), 'utf8');
const env = {...process.env, GOCACHE:path.join(root, '.artifacts/go-cache'), GOTOOLCHAIN:'local', GOPROXY:'off'};
const rapid = process.env.LAWSPEC_RAPID ?? path.join(
  execFileSync('go', ['env','GOMODCACHE'], {encoding:'utf8'}).trim(), 'pgregory.net/rapid@v1.2.0');
const payments = JSON.parse(await read('test/fixtures/native-payments/bindings-go.json'));
const shapes = JSON.parse(await read('test/fixtures/native-shapes/bindings-go.json'));
const scalarTypes = [['Unit','LawSpecUnit'],['Null','LawSpecNull'],['Undefined','LawSpecUndefined'],
  ['Symbol','*LawSpecSymbol'],['Utf16Text','[]uint16'],['Bytes','[]byte'],
  ['Optional (Nullable Int8)','LawSpecOptional[LawSpecNullable[int8]]']];
const scalarSource = 'unit native.scalars\n' + scalarTypes.map(([type],i) =>
  `echo${i} :: ${type} -> ${type}\nlaw \`scalar ${i}\` is definition is \`for all\` (x :: ${type}) . echo${i} x = x end end\n`).join('');
const scalarBindings = scalarTypes.map((_,i) => ({declaration:`native.scalars::echo${i}`,native:[`Echo${i}`]}));
for (const machineBits of [32,64]) for (const minify of [false,true]) {
  const directory = path.join(root, `.artifacts/go-native-payments/${machineBits}-${minify}${nativeGenerators ? '-generators' : ''}${scaffold ? '-stubs' : ''}`);
  if (scaffold) await rm(directory,{recursive:true,force:true});
  const sourceDir = machineBits === 32 ? 'library/native' : '';
  const request = {schemaVersion:4, method:'planGeneration', target:'go', machineBits, minify,
    sourceDir, testDir:sourceDir, generation:{exhaustiveLimit:1},
    nativeBindings:{types:[...payments.types,...shapes.types],functions:[...payments.functions,...shapes.functions,...scalarBindings,
      {declaration:'example.payments::roundTripChecked',native:['Restore']}],
      ...(nativeGenerators ? {generators:[
        {type:'example.payments::type::Money',factory:['NativePrices']},
        {type:'native.shapes::type::Box',factory:['NativeBoxes']},
        {type:'native.shapes::type::Stamp',factory:['NativeSeals']},
        {type:'Int8',factory:['NativeBytes']},
        {type:'Text',factory:['NativeTexts']},
      ]} : {})},
    sources:[{path:'payments.lawspec',content:await read('examples/specs/payments.lawspec') + '\nroundTripChecked :: (payment :: Payment) -> (result :: Payment where result == payment)\n'},
      {path:'shapes.lawspec',content:await read('test/fixtures/native_shapes.lawspec')},
      {path:'scalars.lawspec',content:scalarSource}]};
  if (scaffold) for (const generator of request.nativeBindings.generators) generator.stub = true;
  const result = JSON.parse(execFileSync(compiler, [], {input:JSON.stringify(request),
    encoding:'utf8', maxBuffer:64*1024*1024}));
  assert.deepEqual(result.diagnostics, []);
  assert.deepEqual(await wasm.planGeneration(request),result,'Go native/WASM binding parity');
  for (const file of result.files) {
    assert.equal(file.ownership, scaffold && file.path.endsWith('/native_generators_test.go') ? 'user' : 'generated');
    const destination = path.join(directory,file.path);
    await mkdir(path.dirname(destination),{recursive:true});
    await writeFile(destination,file.content);
    if (!minify && /(?:adapter|lawspec_native_codecs|lawspec_native_generators_test)\.go$/.test(file.path))
      assert.equal(file.content,execFileSync('gofmt',[],{input:file.content,encoding:'utf8'}),file.path);
  }
  const scalarApp = 'package scalars\n\n' + scalarTypes.map(([_,type],i) =>
    `func Echo${i}(value ${type}) ${i === 0 ? '' : type} { ${i === 0 ? '' : 'return value'} }\n`).join('');
  await writeFile(path.join(directory,sourceDir,'native/scalars/domain.go'),scalarApp);
  const paymentPath = path.join(directory,sourceDir,'example/payments/domain.go');
  const domain = await read('test/fixtures/native-payments/domain.go');
  await writeFile(paymentPath,domain);
  await writeFile(path.join(directory,sourceDir,'native/shapes/domain.go'),await read('test/fixtures/native-shapes/domain.go'));
  await writeFile(path.join(directory,sourceDir,'native/shapes/native_codecs_test.go'),await read('test/runtime/GoNativeBindingsCheck.go'));
  await writeFile(path.join(directory,'go.mod'),'module fixture\n\ngo 1.24.0\n\nrequire pgregory.net/rapid v1.2.0\n' +
    `replace pgregory.net/rapid => ${JSON.stringify(rapid)}\n`);
  execFileSync('go',['build','./...'],{cwd:directory,env,stdio:'inherit'});
  async function run(label) {
    const result = spawnSync('go',['test','./...','-rapid.seed=424242','-rapid.nofailfile'],
      {cwd:directory,env,encoding:'utf8',maxBuffer:32*1024*1024});
    const log=(result.stdout ?? '')+(result.stderr ?? '');
    await writeFile(path.join(directory,`${label}.log`),log);
    return {...result,log};
  }
  if (scaffold) {
    const compiled=spawnSync('go',['test','./...','-run','^$'],{cwd:directory,env,encoding:'utf8'});
    assert.equal(compiled.status,0,compiled.stdout+compiled.stderr);
    const missing=await run('unimplemented');
    assert.notEqual(missing.status,0,missing.log);
    assert.match(missing.log,/Implement generator for/);
    assert.doesNotMatch(missing.log,/build failed|undefined:/);
    console.log(`Go ${machineBits}, minify=${minify}: package-local scaffolds compile and fail explicitly`);
    // Replace each generated factory file with the application implementation.
    // Scalar factories are shared with each package's existing common fixture.
    for (const file of result.files.filter(file=>file.ownership==='user')) {
      await writeFile(path.join(directory,file.path),`package ${path.basename(path.dirname(file.path))}\n`);
    }
  }
  if (nativeGenerators) {
    for (const [fixture,packageDir,name] of [
      ['test/fixtures/native-payments/generators.go','example/payments','native_generators_test.go'],
      ['test/fixtures/native-payments/NativeGeneratorContractsCheck.go','example/payments','native_contracts_test.go'],
      ['test/fixtures/native-shapes/generators.go','native/shapes','native_generators_test.go'],
    ]) await writeFile(path.join(directory,sourceDir,packageDir,name),await read(fixture));
    for (const packageDir of ['example/payments','native/shapes','native/scalars']) {
      const content=(await read('test/fixtures/native-payments/generators_common.go')).replace('RUNTIME_PACKAGE',path.basename(packageDir));
      await writeFile(path.join(directory,sourceDir,packageDir,'native_common_test.go'),content);
    }
  }
  const correct=await run('correct');
  assert.equal(correct.status,0,correct.log);
  for (const [label,before,after] of [
    ['fee','big.NewInt(2), power','big.NewInt(3), power'],
    ['currency','exponent}, price.Unit}','exponent}, Dollars}'],
    ['absence','return values','return nil'],
  ]) {
    const changed=domain.replace(before,after);
    assert.notEqual(changed,domain,label);
    await writeFile(paymentPath,changed);
    const invalid=await run(`mutant-${label}`);
    assert.notEqual(invalid.status,0,`${label} survived`);
    assert.match(invalid.log,/--- FAIL:/);
    assert.doesNotMatch(invalid.log,/build failed|undefined:/);
  }
  await writeFile(paymentPath,domain);
  if (nativeGenerators) {
    const shrink = spawnSync('go',['test','./...','-run','^TestNativeMoneyShrink$','-rapid.seed=424242','-rapid.nofailfile'],
      {cwd:directory,env:{...env,LAWSPEC_NATIVE_SHRINK:'1'},encoding:'utf8'});
    const log=shrink.stdout+shrink.stderr;
    await writeFile(path.join(directory,'native-shrink.log'),log);
    assert.notEqual(shrink.status,0);
    assert.match(log,/minimal_money=161\/100/);
    for (const [label,before,after,expected] of [
      ['invalid-generator','rapid.Just("application text")','rapid.Just("\\xff")',/native generator Text/],
      ['exhausted-refinement','rapid.IntRange(6, 20)','rapid.IntRange(0, 0)',/only generated 0 valid tests/],
    ]) {
      const filename=path.join(directory,sourceDir,'native/shapes/native_common_test.go');
      const original=await readFile(filename,'utf8');
      try {
        const changed=original.replace(before,after);
        assert.notEqual(changed,original);
        await writeFile(filename,changed);
        const failure=await run(label);
        assert.notEqual(failure.status,0);
        assert.match(failure.log,expected);
        assert.doesNotMatch(failure.log,/build failed|undefined:/);
      } finally { await writeFile(filename,original); }
    }
  }
  console.log(`Go native payments, recursive shapes and three incorrect adapters passed: ${machineBits}, compact=${minify}`);
}
