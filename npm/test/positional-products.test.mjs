// Generated from templates/npm/test/positional-products.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';
import {createTypePresentation} from '../typed-presentation.mjs';
import {explainLaw} from '../explain.mjs';

const compiler=await createCompiler();
const content=await readFile(new URL('../../test/fixtures/canonical-positional-products.lawspec',import.meta.url),'utf8');
const sources=[{path:'positions.lawspec',content}];
const options={schemaVersion:5,languageProfile:'1.0-rc.2',verification:{layers:['exhaustive','examples']}};
const targets=['java','python','javascript','typescript','go','haskell','kotlin','rust','erlang','elixir','gleam','fsharp','csharp','scala','groovy','clojure','swift'];

test('positional products retain checked outcomes through every target, width and layout',async()=>{
  for(const machineBits of [32,64]) {
    const result=await compiler.check({...options,machineBits,sources});
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.laws.length,7);
    assert.equal(result.laws.reduce((count,law)=>count+law.examples.length,0),5);
    assert.ok(result.evidence.filter(row=>row.stage==='law').every(row=>row.status==='exhaustively-checked'));
    for(const target of targets)for(const minify of [false,true]) {
      const generated=await compiler.planGeneration({...options,machineBits,sources,target,minify});
      assert.deepEqual(generated.diagnostics,[],target+' '+machineBits+' '+minify);
      assert.ok(generated.files.length>0);
    }
  }
});

test('tuple arity, nominal boundaries, hidden shapes and parameter contracts remain mandatory without law layers',async()=>{
  const invalid=[
    `function invalid (value of type (Bool, Bool, Bool)) -> Bool is first matching case of value: when #any then true when (_, _) then false end case end function
`,
    `type Pair is a record{first of type Bool second of type Bool} end type
function invalid ((_, _) of type Pair) -> Bool is true end function
`,
    `function invalid (Present value of type Maybe Integer) -> Bool is true end function
`,
    'function invalid ((same, same) of type (Bool, Bool)) -> Bool is true end function',
    `function bounded ((lower, upper) of type (Integer, Integer) where lower <= upper) -> Integer is upper end function
function invalid (ignored of type ()) -> Integer is bounded (4, 2) end function
`,
    `function invalid ((value, _) of type (UInt8, Bool)) -> UInt8 is value + 1 end function
`,
  ];
  for(const body of invalid) {
    const result=await compiler.check({...options,verification:{layers:[]},sources:[{path:'invalid.lawspec',content:'unit invalid\n'+body+'\nend unit\n'}]});
    assert.ok(result.diagnostics.length>0,body);
    for(const row of result.diagnostics) {
      assert.ok(!row.code.startsWith('block-'),JSON.stringify(row));
      if(row.code==='parse')assert.match(row.message,/repeated variable binding in parameters/);
    }
  }
});

test('formatting retains tuple notation, examples and exact structural identities',async()=>{
  const input={...options,sources};
  const before=await compiler.check(input);
  assert.deepEqual(before.diagnostics,[]);
  const formatted=await compiler.format(input);
  assert.deepEqual(formatted.diagnostics,[]);
  assert.deepEqual((await compiler.format({...input,sources:formatted.formattedSources})).formattedSources,formatted.formattedSources);
  const after=await compiler.check({...input,sources:formatted.formattedSources});
  assert.deepEqual(after.diagnostics,[]);
  const descriptors=result=>result.dataTypes.filter(type=>type.structure).map(type=>[type.id,type.structure.descriptor,type.structure.positions]).sort();
  assert.deepEqual(descriptors(after),descriptors(before));
  assert.deepEqual(after.laws.map(law=>law.examples.length),before.laws.map(law=>law.examples.length));
});

test('all explanation views render tuple positions from typed metadata and retain original obligations',async()=>{
  const result=await compiler.check({...options,sources});
  assert.deepEqual(result.diagnostics,[]);
  const before=structuredClone(result);
  for(const law of result.laws)for(const view of ['developer','business','formal','evidence']) {
    const explanation=explainLaw(law,result,view);
    assert.equal(explanation.assertion,law.assertion);
    assert.deepEqual(explanation.evidence,result.evidence.filter(row=>row.declaration===law.id));
    assert.doesNotMatch(explanation.text,/_tuple\d+_|lawspec::structural|_lawspecParameter/);
  }
  const packet=result.laws.find(law=>law.examples.length===5);
  assert.match(explainLaw(packet,result,'developer').text,/\(record\{ready = true\}, \(true, false\)\)/);
  assert.deepEqual(result,before);
  const domain=await compiler.check({...options,verification:{layers:[]},sources:[{path:'domain.lawspec',content:`unit domain

law dimensions is definition: for all (value of type (Nat, Nat)) => true end for all end definition end law

end unit
`}]});
  assert.deepEqual(domain.diagnostics,[]);
  const type=domain.laws[0].inputs[0].type;
  const spelling=createTypePresentation(domain).typeName(type);
  assert.doesNotMatch(spelling,/_tuple|structural/);
  const roundtrip=await compiler.check({...options,verification:{layers:[]},sources:[{path:'identity.lawspec',content:`unit identity

function identity (value of type ${spelling}) -> ${spelling} is value end function
law sample is definition: identity (1, 2) = (1, 2) end definition end law

end unit
`}]});
  assert.deepEqual(roundtrip.diagnostics,[]);
  const identity=roundtrip.definitions.find(definition=>definition.id.endsWith('::identity'));
  assert.deepEqual(identity.arguments[0].type,type);
});

function mockedTuple() {
  const type=name=>({kind:'constructor',name,arguments:[]});
  return {id:'tuple',name:'TupleStorage',parameters:[],constructors:[{id:'tuple::Record',name:'Record',
    fields:[{id:'right',name:'second',type:type('Bool')},{id:'left',name:'first',type:type('Integer')}]}],
    structure:{kind:'record',positions:['first','second'],fields:[{name:'first',predicates:[]},{name:'second',predicates:[]}]}};
}

test('tuple presentations obey explicit positions while keeping computations in actual order',()=>{
  const declaration=mockedTuple();
  const presentation=createTypePresentation({dataTypes:[declaration]});
  const tupleType={kind:'constructor',name:'tuple',arguments:[]};
  assert.equal(presentation.typeName(tupleType),'(Integer, Bool)');
  const scalar=(type,value)=>({type,value});
  assert.equal(presentation.valueText({kind:'data',type:tupleType,constructor:'tuple::Record',fields:[scalar('Bool',true),scalar('Integer',7)]}),'(7, true)');
  const effect=operation=>({type:tupleType,text:'effect '+operation,node:{kind:'perform',ability:'Trace',operation,arguments:[]}});
  const expression={type:tupleType,text:'ordered construction',node:{kind:'construct',constructor:'tuple::Record',arguments:[effect('second'),effect('first')]}};
  const text=presentation.expressionText(expression,new Map());
  assert.match(text,/let component2 = perform Trace\.second\(\) in let component1 = perform Trace\.first\(\) in \(component1, component2\)/);
  const local={type:tupleType,text:'input',node:{kind:'local',id:'input'}};
  const projected={type:tupleType,text:'projection',node:{kind:'field',constructor:'tuple::Record',index:1,value:local}};
  assert.match(presentation.expressionText(projected,new Map([['input','reading']])),/first matching case of reading: when \(component, #any\) then component end case/);
  const updated={type:tupleType,text:'update',node:{kind:'update',constructor:'tuple::Record',index:1,value:effect('subject'),field:effect('replacement')}};
  const update=presentation.expressionText(updated,new Map());
  assert.ok(update.indexOf('Trace.replacement')<update.indexOf('Trace.subject'));
});

test('invalid or missing position metadata keeps structural and nominal identities explicit',()=>{
  for(const positions of [undefined,[],['first','first'],['missing','second']]) {
    const declaration=mockedTuple();
    declaration.structure.positions=positions;
    const presentation=createTypePresentation({dataTypes:[declaration]});
    assert.equal(presentation.typeName({kind:'constructor',name:'tuple',arguments:[]}),'record{second of type Bool, first of type Integer}');
  }
  const declaration=mockedTuple();
  delete declaration.structure;
  assert.equal(createTypePresentation({dataTypes:[declaration]}).typeName({kind:'constructor',name:'tuple',arguments:[]}),'TupleStorage');
});

test('generic phrase collisions require an explicit identity-based native name override on every target',async()=>{
  const input={...options,verification:{layers:[]},sources:[{path:'collision.lawspec',content:
    `unit collision

function "|same value| (value of type a) -> a is value end function
function sameValue (value of type a) -> a is value end function
law usage is definition: "|same value| true = true and sameValue true = true end definition end law

end unit
`}]};
  const checked=await compiler.check(input);
  assert.deepEqual(checked.diagnostics,[]);
  const instance=checked.units.find(unit=>unit.id==='collision').declarations.find(declaration=>declaration.name.endsWith('_'));
  assert.ok(instance);
  for(const target of targets) {
    const rejected=await compiler.planGeneration({...input,target});
    assert.ok(rejected.diagnostics.some(diagnostic=>diagnostic.code==='native-name-collision'),target);
    const overridden=await compiler.planGeneration({...input,target,nativeBindings:{names:[{declaration:instance.id,name:'distinctIdentity'}]}});
    assert.deepEqual(overridden.diagnostics,[],target);
    assert.ok(overridden.files.length>0);
  }
});
