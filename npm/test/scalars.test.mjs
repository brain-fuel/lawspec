import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';
import {showScalar} from '../scalars.mjs';
const compiler=await createCompiler();
const catalog=await readFile(new URL('../examples/specs/scalar_catalog.lawspec',import.meta.url),'utf8');
const source=content=>[{path:'scalar.lawspec',content}];
test('API v3 retains every scalar representation without JSON number loss',async()=>{
 const result=await compiler.check({sources:source(catalog)});
 assert.deepEqual(result.diagnostics,[]);assert.equal(result.schemaVersion,3);assert.equal(result.machineBits,64);
 const values=Object.fromEntries(result.laws.map(l=>[l.name.split(' representation')[0],l.examples[0].bindings[0].value]));
 assert.equal(Object.keys(values).length,33);
 assert.deepEqual(values.UInt64,{type:'UInt64',value:'18446744073709551615'});
 assert.deepEqual(values.Int64,{type:'Int64',value:'9223372036854775807'});
 assert.deepEqual(values.Rational,{type:'Rational',numerator:'-7',denominator:'11'});
 assert.deepEqual(values.Decimal,{type:'Decimal',coefficient:'1',exponent:'-36'});
 assert.equal(values.Float32.bits,'80000000');assert.equal(values.Float64.bits,'7ff0000000000000');
 assert.deepEqual(values.CodePointText.units,[55296,1114111]);assert.deepEqual(values.Utf16Text.units,[55296,0,65535]);
 assert.deepEqual(values.Bytes.units,[0,128,255]);assert.deepEqual(values['Optional Int8'],{type:'Optional',value:null});
 assert.deepEqual(values['Nullable Int8'],{type:'Nullable',value:{type:'Int8',value:'127'}});
 assert.equal(showScalar(values.UInt64),'18446744073709551615');assert.ok(showScalar(values.Text).includes('😀'));
 for(const law of result.laws)assert.equal(law.assertion.kind,'equal');
});
test('machine profile and request schema have explicit diagnostics',async()=>{
 const content='unit width\nf :: IntSize -> IntSize\nlaw `law` is definition is `equivalent` f f end example `wide` is x = 2147483648 expect f x = 2147483648 end end';
 assert.equal((await compiler.check({sources:source(content),machineBits:32})).diagnostics.length,1);
 assert.deepEqual((await compiler.check({sources:source(content),machineBits:64})).diagnostics,[]);
 assert.match((await compiler.check({sources:[],machineBits:16})).diagnostics[0].message,/32 or 64/);
 assert.match((await compiler.check({sources:[],schemaVersion:2})).diagnostics[0].message,/schemaVersion 3/);
});
test('all targets expose generated runtime source placement independently of ownership',async()=>{
 for(const target of ['java','kotlin','python','javascript','typescript','go','haskell','rust']){
  const result=await compiler.planGeneration({sources:source(catalog),target});
  assert.deepEqual(result.diagnostics,[]);
  const runtimes=result.files.filter(f=>f.placement==='source'&&f.ownership==='generated');
  assert.equal(runtimes.length,target==='rust'?2:1,target);
  assert.equal(result.files.filter(f=>f.placement==='test'&&!f.path.includes('support/')).length,1);
 }
});
test('arithmetic capabilities resolve at specialization and retain safe lexical scope',async()=>{
 const generic='law `numeric` (f :: a -> a) requires Integer a is definition is `for all` (x :: a) . x + 1 = 1 + x end end\n';
 for(const [type,valid] of [['Int8',true],['Text',false]]){
  const content=`unit generic\nf :: ${type} -> ${type}\n${generic}law \`use\` is definition is \`numeric\` f end end`;
  assert.equal((await compiler.check({sources:source(content)})).diagnostics.length===0,valid);
 }
 const content='unit lexical\nx :: Int8 -> BigInt\ng :: Int8 -> BigInt\nlaw `law` is definition is `equivalent` x g end example `one` is x = 1 expect g x = 2 end end';
 for(const target of ['python','javascript','java','haskell'])assert.deepEqual((await compiler.planGeneration({sources:source(content),target})).diagnostics,[]);
});
test('raw literal validation rejects host integer wraparound',async()=>{
 const content='unit bad\nlaw `law` is definition is `for all` (x :: CodePoint) . x = x end example `bad` is x = codePoint(18446744073709551616) expect x = codePoint(0) end end';
 assert.ok((await compiler.check({sources:source(content)})).diagnostics.length);
});
test('generated runtime preserves native byte values, identities, and absence contracts',async()=>{
 const result=await compiler.planGeneration({sources:source(catalog),target:'javascript'});
 const code=result.files.find(f=>f.path.endsWith('lawspec_runtime.mjs')).content;
 const runtime=await import('data:text/javascript;base64,'+Buffer.from(code).toString('base64'));
 const bytes=new Uint8Array([0,128,255]);
 const argument=runtime.convert(bytes,'Bytes');argument[0]=42;
 assert.deepEqual([...bytes],[0,128,255]);
 const resultBytes=runtime.validate(argument,'Bytes');argument[2]=0;
 assert.deepEqual([...resultBytes],[42,128,255]);
 const nested=runtime.convert(new runtime.Presence('Optional',true,bytes),'Optional Bytes');
 nested.value[0]=10;assert.equal(bytes[0],0);
 assert.equal(runtime.unitResult(undefined),runtime.UNIT);
 assert.throws(()=>runtime.unitResult(42),/Unit/);
 assert.equal(runtime.equal(NaN,NaN,'Float64','Float64'),false);
 assert.equal(runtime.equal(0,-0,'Float64','Float64'),true);
 const symbols=new Map();
 const a=runtime.literal({type:'Symbol',id:'a',description:'same'},symbols);
 const b=runtime.literal({type:'Symbol',id:'b',description:'same'},symbols);
 assert.notEqual(a,b);assert.equal(a,runtime.literal({type:'Symbol',id:'a',description:'same'},symbols));
});
