import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const nativeGenerators = process.env.LAWSPEC_NATIVE_GENERATORS === '1';
const {createCompiler} = await import('../npm/api.mjs');
const wasm = await createCompiler();
assert.ok(compiler, 'Set LAWSPEC_CORE');
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
const read = name => readFile(path.join(root,'test/fixtures/native-codecs',name),'utf8');
const nativeBindings = JSON.parse(await read('bindings-kotlin.json'));
const content = (await read('domain.lawspec')).replaceAll('native.codecs','bound.codecs');
const hooks = await read('CodecHooks.kt');
for (const machineBits of [32,64]) for (const minify of [false,true]) {
  const sourceDir = machineBits === 32 ? 'library/native' : 'src/main/kotlin';
  const testDir = machineBits === 32 ? 'checks/native' : 'src/test/kotlin';
  const directory = path.join(root,`.artifacts/kotlin-native-codec-hooks/${machineBits}-${minify}`);
  const request = {schemaVersion:4,method:'planGeneration',target:'kotlin',machineBits,minify,
    sourceDir,testDir,nativeBindings,generation:{exhaustiveLimit:1},sources:[{path:'codecs.lawspec',content}]};
  const result = JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),encoding:'utf8',maxBuffer:64*1024*1024}));
  assert.deepEqual(result.diagnostics,[]);
  assert.deepEqual(await wasm.planGeneration(request),result,'Kotlin codec native/WASM parity');
  const javaFiles=[], kotlinFiles=[], sourceFiles=[], specs=[];
  for (const file of result.files) {
    const destination=path.join(directory,file.path);
    await mkdir(path.dirname(destination),{recursive:true});
    await writeFile(destination,file.content);
    if(destination.endsWith('.java')) javaFiles.push(destination);
    if(destination.endsWith('.kt')) {
      kotlinFiles.push(destination);
      if(file.placement==='source') sourceFiles.push(destination);
    }
    const spec=file.content.match(/class (\w+LawSpecTest) : StringSpec/);
    if(spec) specs.push(file.content.match(/^package ([\w.]+)/m)[1]+'.'+spec[1]);
  }
  for(const name of ['CodecDomain.kt','CodecHooks.kt','CodecGenerators.kt']) {
    const file=path.join(directory,name);
    await writeFile(file,await read(name));
    kotlinFiles.push(file);
    if(name!=='CodecGenerators.kt') sourceFiles.push(file);
  }
  const checkPath=path.join(directory,'KotlinBoundCodecGeneratorCheck.kt');
  await writeFile(checkPath,await readFile(path.join(root,'test/runtime/KotlinBoundCodecGeneratorCheck.kt')));
  kotlinFiles.push(checkPath);
  const classes=path.join(directory,'classes');
  await mkdir(classes,{recursive:true});
  execFileSync('javac',['--release','25','-d',classes,...javaFiles],{encoding:'utf8'});
  const sourceCheck=path.join(directory,'KotlinCodecBindingsCheck.kt');
  await writeFile(sourceCheck,await readFile(path.join(root,'test/runtime/KotlinCodecBindingsCheck.kt')));
  const sourceBuild=spawnSync('kotlinc',['-jvm-target','25','-classpath',classes,...sourceFiles,sourceCheck,'-d',path.join(directory,'source.jar')],{encoding:'utf8'});
  await writeFile(path.join(directory,'source-build.log'),sourceBuild.stdout+sourceBuild.stderr);
  assert.equal(sourceBuild.status,0,sourceBuild.stdout+sourceBuild.stderr);
  const sourceRun=execFileSync('kotlin',['-classpath',path.join(directory,'source.jar')+':'+classes,'KotlinCodecBindingsCheckKt',String(machineBits)],{encoding:'utf8'});
  await writeFile(path.join(directory,'source-check.log'),sourceRun);
  const launcher=path.join(directory,'Main.kt');
  await writeFile(launcher,`import io.kotest.engine.TestEngineLauncher
import io.kotest.engine.listener.CollectingTestEngineListener
fun main() {
  System.setProperty("kotest.framework.classpath.scanning.autoscan.disable", "true")
  domain.checkCodecGenerators(${machineBits})
  val listener = CollectingTestEngineListener()
  val result = TestEngineLauncher(listener).withClasses(${specs.map(s=>s+'::class').join(', ')}).launch()
  result.errors.forEach { it.printStackTrace() }
  val failed = listener.tests.values.filter { it.isErrorOrFailure } + listener.specs.values.filter { it.isErrorOrFailure }
  failed.take(5).forEach { it.errorOrNull?.printStackTrace() }
  check(result.errors.isEmpty() && !listener.errors && failed.isEmpty() && listener.tests.isNotEmpty()) { "generated tests failed" }
  println("Executed " + listener.tests.size + " Kotlin codec tests")
}
`);
  const projectJar=path.join(directory,'project.jar');
  const classpath=classes+':'+dependencies;
  const built=spawnSync('kotlinc',['-J-Xmx3g','-jvm-target','25','-classpath',classpath,...kotlinFiles,launcher,'-d',projectJar],{encoding:'utf8',maxBuffer:32*1024*1024});
  await writeFile(path.join(directory,'build.log'),built.stdout+built.stderr);
  assert.equal(built.status,0,built.stdout+built.stderr);
  async function run(label,extra='') {
    const execution=spawnSync('kotlin',['-J-Xmx2g','-classpath',extra+projectJar+':'+classpath,'MainKt'],{cwd:directory,encoding:'utf8',maxBuffer:32*1024*1024});
    const log=execution.stdout+execution.stderr;
    await writeFile(path.join(directory,label+'.log'),log);
    return {...execution,log};
  }
  const correct=await run('correct');
  assert.equal(correct.status,0,correct.log);
  async function mutant(label,file,source,expected) {
    await writeFile(file,source);
    const jar=path.join(directory,label+'.jar');
    const build=spawnSync('kotlinc',['-jvm-target','25','-classpath',projectJar+':'+classpath,file,'-d',jar],{encoding:'utf8'});
    assert.equal(build.status,0,build.stderr);
    const failed=await run(label,jar+':');
    assert.notEqual(failed.status,0,failed.log);
    assert.match(failed.log,expected);
  }
  const hookPath=path.join(directory,'CodecHooks.kt');
  for(const [label,before,after,expected] of [
    ['decoding-error','CodecDomain.Positive((value as Positive.PositiveCase).value)','error("custom decoding failed")',/Positive toNative: custom decoding failed/],
    ['encoding-error','Positive.PositiveCase(value.unpack())','error("custom encoding failed")',/Positive fromNative: custom encoding failed/],
    ['invalid-result','Positive.PositiveCase(value.unpack())','Positive.PositiveCase(0.toByte())',/field refinement 1 failed/],
    ['collapsed-tail','value.ended()','true',/flattened recursive representation/],
  ]) {
    assert.ok(hooks.includes(before));
    await mutant(label,hookPath,hooks.replace(before,after),expected);
  }
  await writeFile(hookPath,hooks);
  const generators=await read('CodecGenerators.kt');
  await mutant('invalid-generator',path.join(directory,'CodecGenerators.kt'),
    generators.replace('Arb.int(1..100).map { CodecDomain.Positive','Arb.int(0..0).map { CodecDomain.Positive'),
    /native generator.*Positive.*field refinement 1 failed/);
  await writeFile(path.join(directory,'CodecGenerators.kt'),generators);
  console.log(`Kotlin codec hooks: private products, flattened recursion, native shrinking and rejected mutants; ${machineBits}, compact=${minify}`);
}
