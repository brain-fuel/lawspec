import {semanticFacts} from './compiler-input.mjs';
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';
import {targets} from '../templates.mjs';

test('exact widening preserves whole source domains without disabling mandatory checks',async()=>{
  const compiler=await createCompiler();
  const source=(from,to)=>`unit widths

function wider (value of type ${from}) -> ${to} is value end function

end unit
`;
  for(const machineBits of [32,64]){
    const input={schemaVersion:5,languageProfile:'1.0-rc.2',machineBits,verification:{layers:[]}};
    for(const [from,to] of [['Int8','Int16'],['UInt8','Int16'],['UInt8','UInt16'],
      ['Int32','Int64'],['UInt32','Int64'],['IntSize','Int64'],['UIntSize','Integer'],
      ['UInt8','Decimal'],['Int8','Rational'],['Decimal','Rational']]){
      const result=await compiler.check({...input,sources:[{path:'widths.lawspec',content:source(from,to)}]});
      assert.deepEqual(result.diagnostics,[],`${from} -> ${to}/${machineBits}`);
    }
    for(const [from,to] of [['Int16','Int8'],['Int8','UInt16'],['UInt16','Int16'],
      ['UInt64','Int64'],['Integer','Int8'],['Rational','Decimal'],
      ['Float32','Float64'],['Float64','Float32'],['Integer','Float64']]){
      const result=await compiler.check({...input,sources:[{path:'widths.lawspec',content:source(from,to)}]});
      assert.ok(result.diagnostics.length>0,`${from} -> ${to}/${machineBits} requires an explicit conversion`);
    }
    for(const content of [
      'unit widths\nwrapper Count is UInt8 end\n'+source('Count','UInt16').replace('unit widths\n',''),
      source('record{count :: Int8}','record{count :: Int16}'),
      `unit widths

function unsafe (value :: Int8) -> Int16 is prelude.quot value 0 end function

end unit
`]){
      const result=await compiler.check({...input,sources:[{path:'widths.lawspec',content}]});
      assert.ok(result.diagnostics.length>0,'Widening cannot remove nominal, product or definedness checks');
    }
  }
});

test('exact widening examples preserve typed meaning through formatting and all target emitters',async()=>{
  const compiler=await createCompiler();
  const content=await readFile(new URL('../../test/fixtures/canonical-exact-widening.lawspec',import.meta.url),'utf8');
  const sources=[{path:'canonical-exact-widening.lawspec',content}];
  for(const machineBits of [32,64]){
    const input={schemaVersion:5,languageProfile:'1.0-rc.2',machineBits,
      verification:{layers:['property','examples']},sources};
    const before=await compiler.check({...input});
    assert.deepEqual(before.diagnostics,[]);
    assert.equal(before.laws.length,6);
    assert.equal(before.laws.flatMap(law=>law.examples).length,19);
    const formatted=await compiler.format(input);assert.deepEqual(formatted.diagnostics,[]);
    const after=await compiler.check({...input,sources:formatted.formattedSources});
    assert.deepEqual(after.diagnostics,[]);

    assert.deepEqual(semanticFacts(after),semanticFacts(before));
    const twice=await compiler.format({...input,sources:formatted.formattedSources});
    assert.deepEqual(twice.formattedSources,formatted.formattedSources);
    for(const target of targets){
      const result=await compiler.planGeneration({...input,target,minify:machineBits===32});
      assert.deepEqual(result.diagnostics,[],`${target}/${machineBits}`);
      assert.ok(result.files.length>0);
    }
  }
});
