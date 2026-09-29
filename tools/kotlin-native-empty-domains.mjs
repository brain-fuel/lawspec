import assert from 'node:assert/strict';
import {execFileSync,spawnSync} from 'node:child_process';
import {mkdir,writeFile,readFile,readdir,rm} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';
const root=path.resolve(import.meta.dirname,'..');
const compiler=process.env.LAWSPEC_CORE;
assert.ok(compiler,'Set LAWSPEC_CORE');
const wasm=await createCompiler();
const source=await readFile(path.join(root,'test/fixtures/native_empty_domains.lawspec'),'utf8');
async function jars(directory){return (await Promise.all((await readdir(directory,{withFileTypes:true})).map(entry=>entry.isDirectory()?jars(path.join(directory,entry.name)):[path.join(directory,entry.name)]))).flat().filter(file=>file.endsWith('.jar')&&!file.endsWith('-sources.jar'));}
const cache=path.join(process.env.HOME,'.gradle/caches/modules-2/files-2.1');
const dependencies=(await Promise.all(['io.kotest','io.github.classgraph','com.github.ajalt','org.opentest4j',
 'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.8.0','org.jetbrains.kotlinx/kotlinx-coroutines-test-jvm/1.8.0',
 'org.jetbrains.kotlinx/kotlinx-coroutines-debug/1.8.0'].map(group=>jars(path.join(cache,group))))).flat().join(path.delimiter);
for(const machineBits of [32,64]) for(const minify of [false,true]){
 const directory=path.join(root,'.artifacts/kotlin-native-empty-domains',`${machineBits}-${minify}`);
 await rm(directory,{recursive:true,force:true});await mkdir(directory,{recursive:true});
 const sourceDir=machineBits===32?'library/native':'src/main/kotlin';
 const testDir=machineBits===32?'checks/native':'src/test/kotlin';
 const request={schemaVersion:4,method:'planGeneration',target:'kotlin',machineBits,minify,sourceDir,testDir,
  generation:{exhaustiveLimit:1},sources:[{path:'empty.lawspec',content:source}],nativeBindings:{generators:[
   {type:'example.empty::type::Phantom',factory:['application','Factories','phantoms']},
   {type:'List',factory:['application','Factories','lists']}]}};
 const result=JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),encoding:'utf8',maxBuffer:32*1024*1024}));
 assert.deepEqual(result.diagnostics,[]);assert.deepEqual(await wasm.planGeneration(request),result);
 const put=async(file,content)=>{const dest=path.join(directory,file);await mkdir(path.dirname(dest),{recursive:true});await writeFile(dest,content);};
 for(const file of result.files) await put(file.path,file.content);
 await mkdir(path.join(directory,'classes'),{recursive:true});
 execFileSync('javac',['--release','25','-d','classes',...result.files.filter(file=>file.path.endsWith('.java')).map(file=>file.path)],{cwd:directory,encoding:'utf8'});
 const factory=`package application
import io.kotest.property.Arb
import io.kotest.property.arbitrary.int
import io.kotest.property.arbitrary.map
import lawspec.data.Phantom

object Factories {
    fun <T> phantoms(child: Arb<T>): Arb<Phantom<T>> =
        Arb.int(40..100).map { value -> Phantom.PhantomCase<T>(value.toByte()) }

    fun <T> lists(child: Arb<T>): Arb<List<T>> = error("finite List Empty must be enumerated")
}
`;
 const factoryPath=`${testDir}/application/Factories.kt`;
 await put(factoryPath,factory);
 const specs=result.files.filter(file=>file.path.endsWith('LawSpecTest.kt')).map(file=>file.path.slice(testDir.length+1).replace(/\.kt$/,'').replaceAll('/','.'));
 assert.ok(specs.length);
 await put('Main.kt',`import io.kotest.engine.TestEngineLauncher
import io.kotest.engine.listener.CollectingTestEngineListener
fun main() {
    System.setProperty("kotest.framework.classpath.scanning.autoscan.disable", "true")
    for (spec in listOf(${specs.map(spec=>`${spec}::class`).join(', ')})) {
        val listener = CollectingTestEngineListener()
        val result = TestEngineLauncher(listener).withClasses(spec).launch()
        val failed = listener.tests.values.filter { it.isErrorOrFailure } + listener.specs.values.filter { it.isErrorOrFailure }
        failed.forEach { it.errorOrNull?.printStackTrace() }
        check(result.errors.isEmpty() && !listener.errors && failed.isEmpty() && listener.tests.isNotEmpty())
    }
}
`);
 const classpath=[path.join(directory,'classes'),dependencies].join(path.delimiter);
 const run=()=>{
  execFileSync('kotlinc',['-J-Xmx3g','-jvm-target','25','-classpath',classpath,...result.files.filter(file=>file.path.endsWith('.kt')).map(file=>file.path),factoryPath,'Main.kt','-d','project.jar'],{cwd:directory,encoding:'utf8',maxBuffer:32*1024*1024});
  return spawnSync('kotlin',['-classpath',path.join(directory,'project.jar')+path.delimiter+classpath,'MainKt'],{cwd:directory,encoding:'utf8',timeout:30000,maxBuffer:32*1024*1024});
 };
 const correct=run();await put('correct.log',correct.stdout+correct.stderr);assert.equal(correct.status,0,correct.stdout+correct.stderr);
 await put(factoryPath,factory.replace('Arb.int(40..100).map { value -> Phantom.PhantomCase<T>(value.toByte()) }','child.map { Phantom.PhantomCase<T>(40.toByte()) }'));
 const impossible=run();await put('impossible.log',impossible.stdout+impossible.stderr);
 assert.equal(impossible.error,undefined);assert.notEqual(impossible.status,0);assert.match(impossible.stdout+impossible.stderr,/no native generator argument.*Empty/);
 console.log(`Kotlin ${machineBits}, minify=${minify}: ignored Empty works, demanded Empty fails, List Empty enumerates`);
}
