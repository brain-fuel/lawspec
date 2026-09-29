// Verify native JetCheck scaffold signatures across the complete scalar catalog.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, writeFile, rm} from 'node:fs/promises';
import path from 'node:path';
import {templates} from '../npm/templates.mjs';
import {createCompiler} from '../npm/api.mjs';
const root=path.resolve(import.meta.dirname,'..');
const compiler=process.env.LAWSPEC_CORE;
assert.ok(compiler,'Set LAWSPEC_CORE');
const wasm=await createCompiler();
const scalars=['Bool',...['Int','UInt'].flatMap(prefix=>[8,16,32,64].map(width=>prefix+width)),
  'IntSize','UIntSize','UIntPtr','Integer','BigInt','BigUInt','Decimal','Rational',
  'Float32','Float64','Complex64','Complex128','Char','CodePoint','CodeUnit16',
  'Text','CodePointText','Utf16Text','Bytes','Symbol','Unit','Null','Undefined'];
const generators=[...scalars,'List','Maybe','Either','Nullable','Optional'].map(type=>({
  type,factory:['factories','Factories',`make${type}`],stub:true,
}));
generators.push({type:'catalog::type::Wrap',factory:['factories','Factories','wrap'],stub:true},
  {type:'catalog::type::Box',factory:['factories','Factories','box'],stub:true});
const source='unit catalog\ntype Wrap (a :: Type) is Wrap value :: a end\ntype Box (a :: Type) is Box value :: a end';
for(const machineBits of [32,64]) for(const minify of [false,true]) {
  const output=path.join(root,'.artifacts/java-generator-scaffolds',`${machineBits}-${minify}`);
  await rm(output,{recursive:true,force:true});
  await mkdir(output,{recursive:true});
  const sourceDir='library/native',testDir='checks/native';
  const request={schemaVersion:4,method:'planGeneration',target:'java',machineBits,minify,sourceDir,testDir,
    sources:[{path:'catalog.lawspec',content:source}],nativeBindings:{generators,types:[{
      type:'catalog::type::Box',native:['types','NativeBox'],constructors:[{constructor:'Box',
        native:['types','NativeBox'],style:'record',fields:[{field:'value',native:'value'}]}],
    }]}};
  const result=JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),encoding:'utf8',maxBuffer:32*1024*1024}));
  assert.deepEqual(result.diagnostics,[]);
  assert.deepEqual(await wasm.planGeneration(request),result,'Java scaffold native/WASM parity');
  const put=async(relative,content)=>{
    const file=path.join(output,relative);
    await mkdir(path.dirname(file),{recursive:true});
    await writeFile(file,content);
  };
  for(const file of result.files) await put(file.path,file.content);
  const pom=templates('java')['pom.xml'].replace('<build>',
    `<build><sourceDirectory>${sourceDir}</sourceDirectory><testSourceDirectory>${testDir}</testSourceDirectory>`);
  await put('pom.xml',pom);
  await put(`${sourceDir}/types/NativeBox.java`,'package types; public record NativeBox<T>(T value) {}\n');
  const checks=`package checks;
import org.jetbrains.jetCheck.Generator;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.assertThrows;
import factories.Factories;
public class ScaffoldTest {
  static void signatures(Generator<Integer> child) {
    Generator<types.NativeBox<Integer>> box = Factories.box(child);
    Generator<lawspec.data.Wrap<Integer>> wrap = Factories.wrap(child);
    Generator<java.util.List<Integer>> list = Factories.makeList(child);
  }
  @Test void unimplementedFactoriesFailExplicitly() {
    assertThrows(UnsupportedOperationException.class, () -> Factories.makeInt8());
    assertThrows(UnsupportedOperationException.class, () -> Factories.makeUnit());
    assertThrows(UnsupportedOperationException.class, () -> Factories.makeDecimal());
    assertThrows(UnsupportedOperationException.class, () -> Factories.box(Generator.integers(0, 10)));
    assertThrows(UnsupportedOperationException.class, () -> Factories.makeEither(Generator.integers(0, 10), Generator.integers(0, 10)));
  }
}
`;
  await put(`${testDir}/checks/ScaffoldTest.java`,checks);
  execFileSync('mvn',['-o','-q','compile'],{cwd:output,encoding:'utf8'});
  execFileSync('mvn',['-o','-q','test'],{cwd:output,encoding:'utf8'});
  await put(`${testDir}/checks/Wrong.java`,
    'package checks; class Wrong { org.jetbrains.jetCheck.Generator<String> wrong = factories.Factories.makeInt8(); }');
  const wrong=spawnSync('mvn',['-o','-q','test-compile'],{cwd:output,encoding:'utf8'});
  assert.notEqual(wrong.status,0);
  assert.match((wrong.stdout??'')+(wrong.stderr??''),/incompatible types/);
  await rm(path.join(output,testDir,'checks/Wrong.java'));
  console.log(`Java ${machineBits}, minify=${minify}: scalar/container/native generic signatures compile, wrong types rejected, stubs fail explicitly`);
}
