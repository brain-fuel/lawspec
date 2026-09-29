import assert from 'node:assert/strict';
import test from 'node:test';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
const extension=process.env.LAWSPEC_DATA_EXTENSION ?? 'mjs';
const load=(dir,name)=>import(pathToFileURL(path.join(dir,`${name}.${extension}`)).href);
const [data,schema,generators,fc]=await Promise.all([
  load(process.env.LAWSPEC_DATA_DIR,'lawspec_data'),
  load(process.env.LAWSPEC_DATA_DIR,'lawspec_schema'),
  load(process.env.LAWSPEC_STRATEGIES_DIR,'lawspec_native_generators'),
  import(pathToFileURL(process.env.LAWSPEC_FAST_CHECK).href),
]);
test('generic application codecs retain native child shrinking',()=>{
  const arbitrary=generators.strategy(data.makeSchema(),new schema.Named(
    'native.codecs::type::Parcel',[new schema.Named('Int8')]),64,64,
    ()=>fc.integer({min:1,max:100}));
  const result=fc.check(fc.property(arbitrary,value=>value.fields[0]<=60),{seed:2026,numRuns:100});
  assert.equal(result.failed,true);
  assert.equal(result.counterexample[0].fields[0],61);
  assert.ok(result.numShrinks>0);
});
