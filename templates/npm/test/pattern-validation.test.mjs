import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createCompiler} from '../api.mjs';

const compiler=await createCompiler();
const options={schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]}};
const request=(content,machineBits=64)=>({...options,machineBits,sources:[{path:'patterns.lawspec',content:'unit patterns\n'+content}]});
const declaration=(type,rows)=>'function selected (value of type '+type+') -> Bool is first matching case of value: '+rows+' end case end function';
const packet='type Packet is one of | Missing | Wrapped of type record{flag of type Bool} end type\n';

const invalid=[
  ...['Integer','Bool','List Bool','a'].map(type=>declaration(type,'when #any then true when record{} then false')),
  declaration('record{flag of type Bool}','when #any then true when record{missing = ignored} then false'),
  declaration('record{child of type record{flag of type Bool}}','when #any then true when record{child = record{missing = ignored}} then false'),
  packet+declaration('Packet','when #any then true when Wrapped record{missing = ignored} then false'),
  packet+declaration('Packet','when Wrapped ignored then true when Missing then false when Wrapped record{missing = ignored} then false'),
  packet+declaration('Bool','when #any then true when Missing then false'),
  declaration('Bool','when #any then true when 3 then false'),
  declaration('Integer','when #any then true when true then false'),
];

test('every authored pattern shape is checked before ordered rows are discarded, with no law layers',async()=>{
  for(const machineBits of [32,64])for(const content of invalid) {
    const result=await compiler.check(request(content,machineBits));
    assert.ok(result.diagnostics.length>0,content);
    assert.ok(result.diagnostics.every(row=>row.code!=='parse'),JSON.stringify(result.diagnostics));
  }
});

test('valid shadowed generic and GADT patterns retain their own field types and first-match outcomes',async()=>{
  const content=[
    declaration('record{item of type a}','when #any then true when record{item = ignored} then false when record{} then false'),
    'type Value (a of type Type) is one of | Number of type record{value of type Integer} where a = Integer | Truth of type record{value of type Bool} where a = Bool end type',
    'function read (expression of type Value a) -> a is first matching case of expression: when Number record{value = number} then number when Truth record{value = boolean} then boolean when Number record{value = 3} then 3 when Truth record{value = true} then true end case end function',
    'law outcomes is definition: selected record{item = 3} = true and read (Number record{value = 7}) = 7 and read (Truth record{value = false}) = false end end',
  ].join('\n');
  for(const machineBits of [32,64]) {
    const result=await compiler.check({...request(content,machineBits),verification:{layers:['exhaustive']}});
    assert.deepEqual(result.diagnostics,[]);
    assert.ok(result.evidence.some(row=>row.stage==='law'&&row.status==='exhaustively-checked'));
    const expanded=await compiler.expand(request(content,machineBits));
    assert.deepEqual(expanded.diagnostics,[]);
    assert.ok(!JSON.stringify(expanded).includes('prelude.selection-validation:'));
  }
});

test('formatting retains valid shadowed patterns and reports invalid hidden shapes',async()=>{
  const invalidResult=await compiler.format(request(invalid[4]));
  assert.ok(invalidResult.diagnostics.some(row=>row.message.includes('missing')));
  assert.equal(invalidResult.formattedSources,undefined);
  const input=request(declaration('record{flag of type Bool}','when #any then true when record{flag = false} then false'));
  const formatted=await compiler.format(input);
  assert.deepEqual(formatted.diagnostics,[]);
  assert.ok(formatted.formattedSources[0].content.includes('flag = false'));
  assert.deepEqual((await compiler.format({...input,sources:formatted.formattedSources})).formattedSources,formatted.formattedSources);
  assert.deepEqual((await compiler.check({...input,sources:formatted.formattedSources})).diagnostics,[]);
});
