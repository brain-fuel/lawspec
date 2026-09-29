// Execute exported application projects using the installed compiler and cached dependencies.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFile,writeFile,symlink,mkdir,readdir} from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const root=path.resolve(import.meta.dirname,'..');
const base=path.join(root,'.artifacts/native-example-package');
const installed=path.join(base,'installation/node_modules/lawspec');
const {createCompiler}=await import(pathToFileURL(path.join(installed,'api.mjs')));
const {planWrites,applyWrites}=await import(pathToFileURL(path.join(installed,'files.mjs')));
const compiler=await createCompiler();
const selected=process.argv.slice(2);
assert.ok(selected.length,'Pass target names: python javascript typescript go java haskell kotlin');
async function filesIn(directory) {
  return (await Promise.all((await readdir(directory,{withFileTypes:true})).map(entry=>
    entry.isDirectory()?filesIn(path.join(directory,entry.name)):[path.join(directory,entry.name)]))).flat();
}
for(const target of selected){
  assert.ok(['python','javascript','typescript','go','java','haskell','kotlin'].includes(target),`Unsupported runtime harness target: ${target}`);
  const directory=path.join(base,'workspace/native_payments',target);
  const config=JSON.parse(await readFile(path.join(directory,'lawspec.json'),'utf8'));
  const content=await readFile(path.join(directory,'laws/payments.lawspec'),'utf8');
  const result=await compiler.planGeneration({target,machineBits:config.machineBits,
    sources:[{path:'laws/payments.lawspec',content}],nativeBindings:config.targets[0].nativeBindings});
  assert.deepEqual(result.diagnostics,[]);
  await applyWrites([await planWrites(directory,result.files)]);
  const env={...process.env};
  const run=(command,args)=>execFileSync(command,args,{cwd:directory,env,encoding:'utf8',maxBuffer:32*1024*1024});
  let output;
  if(target==='python'){
    env.PYTHONDONTWRITEBYTECODE='1';
    env.PYTHONPATH=[path.join(directory,'src'),path.join(directory,'tests'),
      process.env.LAWSPEC_PYTHON_DEPS ?? path.join(root,'.artifacts/python-data-deps')].join(path.delimiter);
    output=run(process.env.LAWSPEC_PYTHON ?? 'python3.13',['-B','-m','pytest','-q','--tb=short']);
  } else if(target==='javascript'||target==='typescript'){
    await symlink(process.env.LAWSPEC_WEB_DEPS ?? path.join(root,'.artifacts/lists/javascript/node_modules'),
      path.join(directory,'node_modules')).catch(error=>{if(error.code!=='EEXIST') throw error;});
    if(target==='typescript') run(process.execPath,[path.join(root,'.artifacts/web-data-deps/typescript/bin/tsc'),'-p','.']);
    const tests=result.files.filter(file=>file.path.includes('.lawspec.test.')).map(file=>
      target==='typescript'?'dist/'+file.path.replace(/\.ts$/,'.js'):file.path);
    output=run(process.execPath,['--test',...tests]);
  } else if(target==='go'){
    env.GOCACHE=path.join(root,'.artifacts/go-cache');env.GOTOOLCHAIN='local';env.GOPROXY='off';
    run('go',['mod','download']);
    output=run('go',['test','-mod=mod','./...']);
  } else if(target==='haskell'){
    assert.ok(process.env.LAWSPEC_GHC,'Set LAWSPEC_GHC');
    const database=process.env.LAWSPEC_GHC_PACKAGE_DB;
    if(database) env.PATH=path.join(path.dirname(database),'bin')+path.delimiter+env.PATH;
    run(process.env.LAWSPEC_GHC,[...(database?['-package-db',database]:[]),'--make','test/Spec.hs',
      '-isrc','-itest','-outputdir','build','-o','check']);
    output=run(path.join(directory,'check'),[]);
  } else if(target==='kotlin'){
    const cache=path.join(process.env.HOME,'.gradle/caches/modules-2/files-2.1');
    const jars=(await Promise.all(['io.kotest','io.github.classgraph','com.github.ajalt','org.opentest4j',
      'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.8.0',
      'org.jetbrains.kotlinx/kotlinx-coroutines-test-jvm/1.8.0',
      'org.jetbrains.kotlinx/kotlinx-coroutines-debug/1.8.0'].map(group=>filesIn(path.join(cache,group)))))
      .flat().filter(file=>file.endsWith('.jar')&&!file.endsWith('-sources.jar'));
    const sources=await filesIn(path.join(directory,'src'));
    await mkdir(path.join(directory,'classes'),{recursive:true});
    run('javac',['--release','25','-d','classes',...sources.filter(file=>file.endsWith('.java'))]);
    const specs=result.files.filter(file=>file.path.endsWith('LawSpecTest.kt')).map(file=>
      file.path.replace('src/test/kotlin/','').replace(/\.kt$/,'').replaceAll('/','.'));
    assert.ok(specs.length);
    await writeFile(path.join(directory,'Main.kt'),`import io.kotest.engine.TestEngineLauncher
import io.kotest.engine.listener.CollectingTestEngineListener
fun main() {
    System.setProperty("kotest.framework.classpath.scanning.autoscan.disable", "true")
    var total = 0
    for (spec in listOf(${specs.map(spec=>`${spec}::class`).join(', ')})) {
        val listener = CollectingTestEngineListener()
        val result = TestEngineLauncher(listener).withClasses(spec).launch()
        val failed = listener.tests.values.filter { it.isErrorOrFailure } + listener.specs.values.filter { it.isErrorOrFailure }
        failed.forEach { it.errorOrNull?.printStackTrace() }
        check(result.errors.isEmpty() && !listener.errors && failed.isEmpty() && listener.tests.isNotEmpty())
        total += listener.tests.size
    }
    println("Executed " + total + " generated Kotlin tests")
}
`);
    const classpath=[path.join(directory,'classes'),...jars].join(path.delimiter);
    run('kotlinc',['-J-Xmx3g','-jvm-target','25','-classpath',classpath,
      ...sources.filter(file=>file.endsWith('.kt')),'Main.kt','-d','project.jar']);
    output=run('kotlin',['-J-Xmx2g','-classpath',path.join(directory,'project.jar')+path.delimiter+classpath,'MainKt']);
  } else {
    output=run('mvn',['-o','-q','test']);
  }
  await writeFile(path.join(base,`${target}-tests.log`),output);
  console.log(`Installed ${target} project: generated native payment tests pass`);
}
