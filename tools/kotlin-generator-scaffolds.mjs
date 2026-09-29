// Check native Kotest scaffold types, including generic and tagged containers.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readdir, writeFile, rm} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';
const root=path.resolve(import.meta.dirname,'..');
const compiler=process.env.LAWSPEC_CORE;
assert.ok(compiler,'Set LAWSPEC_CORE');
const wasm=await createCompiler();
const cache = path.join(process.env.HOME, '.gradle/caches/modules-2/files-2.1');
async function jars(directory) {
  const entries = await readdir(directory, {withFileTypes: true});
  return (await Promise.all(entries.map(entry => entry.isDirectory()
    ? jars(path.join(directory, entry.name)) : [path.join(directory, entry.name)])))
    .flat().filter(file => file.endsWith('.jar') && !file.endsWith('-sources.jar'));
}
const dependencies = (await Promise.all([
  'io.kotest', 'io.github.classgraph', 'com.github.ajalt', 'org.opentest4j',
  'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.8.0',
  'org.jetbrains.kotlinx/kotlinx-coroutines-test-jvm/1.8.0',
  'org.jetbrains.kotlinx/kotlinx-coroutines-debug/1.8.0',
].map(group => jars(path.join(cache, group))))).flat().join(':');
const scalars=['Bool',...['Int','UInt'].flatMap(prefix=>[8,16,32,64].map(width=>prefix+width)),
  'IntSize','UIntSize','UIntPtr','Integer','BigInt','BigUInt','Decimal','Rational',
  'Float32','Float64','Complex64','Complex128','Char','CodePoint','CodeUnit16',
  'Text','CodePointText','Utf16Text','Bytes','Symbol','Unit','Null','Undefined'];
const generators=[...scalars,'List','Maybe','Either','Nullable','Optional'].map(type=>({
  type,factory:['factories','Factories',`make${type}`],stub:true,
}));
generators.push({type:'catalog::type::Wrap',factory:['factories','Factories','wrap'],stub:true},
  {type:'catalog::type::Box',factory:['factories','Factories','box'],stub:true});
for(const machineBits of [32,64]) for(const minify of [false,true]) {
  const directory=path.join(root,'.artifacts/kotlin-generator-scaffolds',`${machineBits}-${minify}`);
  await rm(directory,{recursive:true,force:true});
  await mkdir(directory,{recursive:true});
  const request={schemaVersion:4,method:'planGeneration',target:'kotlin',machineBits,minify,
    sourceDir:'library/native',testDir:'checks/native',sources:[{path:'catalog.lawspec',content:
      'unit catalog\ntype Wrap (a :: Type) is Wrap value :: a end\ntype Box (a :: Type) is Box value :: a end'}],
    nativeBindings:{generators,types:[{type:'catalog::type::Box',native:['types','NativeBox'],constructors:[
      {constructor:'Box',native:['types','NativeBox'],style:'record',fields:[{field:'value',native:'value'}]},
    ]}]}};
  const result=JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),encoding:'utf8',maxBuffer:64*1024*1024}));
  assert.deepEqual(result.diagnostics,[]);
  assert.deepEqual(await wasm.planGeneration(request),result);
  const sourceKotlin=[],testKotlin=[],java=[];
  const put=async(relative,content)=>{
    const file=path.join(directory,relative);
    await mkdir(path.dirname(file),{recursive:true});
    await writeFile(file,content);
    return file;
  };
  for(const file of result.files) {
    const target=await put(file.path,file.content);
    if(target.endsWith('.java')) java.push(target);
    else if(target.endsWith('.kt')) (file.placement==='source'?sourceKotlin:testKotlin).push(target);
  }
  sourceKotlin.push(await put('library/native/types/NativeBox.kt',
    'package types\ndata class NativeBox<T>(val value: T)\n'));
  const classes=path.join(directory,'classes');
  await mkdir(classes,{recursive:true});
  execFileSync('javac',['--release','25','-d',classes,...java],{encoding:'utf8'});
  const compile=(files,classpath,jar)=>spawnSync('kotlinc',['-J-Xmx3g','-jvm-target','25','-classpath',classpath,
    ...files,'-d',jar],{encoding:'utf8',maxBuffer:32*1024*1024});
  const sourceOnly=compile(sourceKotlin,classes,path.join(directory,'source.jar'));
  assert.equal(sourceOnly.status,0,sourceOnly.stdout+sourceOnly.stderr);
  const main=await put('ScaffoldMain.kt',`import io.kotest.property.Arb
import io.kotest.property.arbitrary.constant
import factories.Factories
fun signatures(child: Arb<Int>) {
    val box: Arb<types.NativeBox<Int>> = Factories.box(child)
    val wrap: Arb<lawspec.data.Wrap<Int>> = Factories.wrap(child)
    val list: Arb<List<Int>> = Factories.makeList(child)
}
fun main() {
    for (factory in listOf<() -> Any>(
        { Factories.makeInt8() }, { Factories.makeUnit() },
        { Factories.makeDecimal() }, { Factories.box(Arb.constant(1)) },
        { Factories.makeNullable(Arb.constant(1)) },
        { Factories.makeEither(Arb.constant(1), Arb.constant("text")) }
    )) {
        try { factory(); error("expected unimplemented factory") }
        catch (error: NotImplementedError) {
            check(error.message!!.contains("Implement generator for"))
        }
    }
}
`);
  const classpath=`${classes}:${dependencies}`, jar=path.join(directory,'project.jar');
  const built=compile([...sourceKotlin,...testKotlin,main],classpath,jar);
  assert.equal(built.status,0,built.stdout+built.stderr);
  execFileSync('kotlin',['-classpath',`${jar}:${classpath}`,'ScaffoldMainKt'],{encoding:'utf8'});
  const wrong=await put('Wrong.kt','val wrong: io.kotest.property.Arb<String> = factories.Factories.makeInt8()\n');
  const rejected=compile([wrong],`${jar}:${classpath}`,path.join(directory,'wrong.jar'));
  assert.notEqual(rejected.status,0);
  assert.match(rejected.stdout+rejected.stderr,/type mismatch/);
  console.log(`Kotlin ${machineBits}, minify=${minify}: all signatures compile, wrong types rejected, scaffold bodies fail explicitly`);
}
