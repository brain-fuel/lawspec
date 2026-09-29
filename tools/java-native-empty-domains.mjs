import assert from 'node:assert/strict';
import {execFileSync,spawnSync} from 'node:child_process';
import {mkdir,writeFile,readFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';
import {templates} from '../npm/templates.mjs';
const root=path.resolve(import.meta.dirname,'..');
const compiler=process.env.LAWSPEC_CORE;
assert.ok(compiler,'Set LAWSPEC_CORE');
const wasm=await createCompiler();
const source=await readFile(path.join(root,'test/fixtures/native_empty_domains.lawspec'),'utf8');
for(const machineBits of [32,64]) for(const minify of [false,true]){
 const directory=path.join(root,'.artifacts/java-native-empty-domains',`${machineBits}-${minify}`);
 await rm(directory,{recursive:true,force:true});
 await mkdir(directory,{recursive:true});
 const request={schemaVersion:4,method:'planGeneration',target:'java',machineBits,minify,
  generation:{exhaustiveLimit:1},sources:[{path:'empty.lawspec',content:source}],nativeBindings:{generators:[
   {type:'example.empty::type::Phantom',factory:['application','Factories','phantoms']},
   {type:'List',factory:['application','Factories','lists']}]}};
 const result=JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),encoding:'utf8',maxBuffer:32*1024*1024}));
 assert.deepEqual(result.diagnostics,[]);
 assert.deepEqual(await wasm.planGeneration(request),result);
 const put=async(file,content)=>{const dest=path.join(directory,file);await mkdir(path.dirname(dest),{recursive:true});await writeFile(dest,content);};
 for(const file of result.files) await put(file.path,file.content);
 await put('pom.xml',templates('java')['pom.xml']);
 const factory=`package application;

import java.util.List;
import lawspec.data.Phantom;
import org.jetbrains.jetCheck.Generator;

public final class Factories {
  private Factories() {}

  public static <T> Generator<Phantom<T>> phantoms(Generator<T> child) {
    return Generator.integers(40, 100).map(value -> new Phantom.PhantomCase<T>(value.byteValue()));
  }

  public static <T> Generator<List<T>> lists(Generator<T> child) {
    throw new AssertionError("finite List Empty must be enumerated");
  }
}
`;
 const factoryPath='src/test/java/application/Factories.java';
 await put(factoryPath,factory);
 const run=()=>spawnSync('mvn',['-o','-q','test'],{cwd:directory,encoding:'utf8',maxBuffer:32*1024*1024,timeout:60000});
 const correct=run();await put('correct.log',correct.stdout+correct.stderr);
 assert.equal(correct.status,0,correct.stdout+correct.stderr);
 await put(factoryPath,factory.replace('Generator.integers(40, 100)','child.map(ignored -> 40)'));
 const impossible=run();await put('impossible.log',impossible.stdout+impossible.stderr);
 assert.equal(impossible.error,undefined);
 assert.notEqual(impossible.status,0);
 assert.match(impossible.stdout+impossible.stderr,/CannotSatisfyCondition/);
 console.log(`Java ${machineBits}, minify=${minify}: ignored Empty works, demanded Empty fails, List Empty enumerates`);
}
