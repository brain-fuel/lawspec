// Generated from templates/npm/test/record-predicate-functions.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';
import {explainLaw} from '../explain.mjs';

const compiler=await createCompiler();
const path='test/fixtures/canonical-record-predicate-functions.lawspec';
const content=await readFile(new URL('../../'+path,import.meta.url),'utf8');
const sources=[{path,content}];
const options={schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:['exhaustive','examples']}};
const targets=['java','python','javascript','typescript','go','haskell','kotlin','rust','erlang','elixir','gleam','fsharp','csharp','scala','groovy','clojure','swift'];

test('checked predicates in structural record fields retain their obligations across targets, widths and layouts',async()=>{
  for(const machineBits of [32,64]) {
    const result=await compiler.check({...options,machineBits,sources});
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.laws.length,6);
    assert.equal(result.laws.reduce((count,law)=>count+law.examples.length,0),14);
    const laws=result.evidence.filter(row=>row.stage==='law');
    assert.equal(laws.length,6);
    assert.ok(laws.every(row=>row.status==='exhaustively-checked'));
    for(const target of targets)for(const minify of [false,true]) {
      const generated=await compiler.planGeneration({...options,machineBits,sources,target,minify});
      assert.deepEqual(generated.diagnostics,[],target+' '+machineBits+' '+minify);
      assert.ok(generated.files.length>0);
    }
  }
});

test('original record predicate calls retain type, precondition, scope and runtime-contract admission without law layers',async()=>{
  const invalid=[
  {
    "expected": "definition",
    "body": "function keep (n :: Bool) -> Bool is true end function\nfunction invalid (input :: record{value :: (n :: UInt8 where keep n)}) -> Bool is true end function"
  },
  {
    "expected": "total",
    "body": "function keep (n :: (v :: UInt8 where v > 0)) -> Bool is true end function\nfunction invalid (input :: record{value :: (n :: UInt8 where keep n)}) -> Bool is true end function"
  },
  {
    "expected": "definition",
    "body": "function keep (n :: Bool) -> Bool is true end function\ntype Number is a record{value :: (n :: UInt8 where keep n)} end type"
  },
  {
    "expected": "definition",
    "body": "function keep (n :: Bool) -> Bool is true end function\nfunction invalid (input :: record{inner :: record{value :: (n :: UInt8 where keep n)}}) -> Bool is true end function"
  },
  {
    "expected": "data-type",
    "body": "function keep (n :: UInt8) -> Bool is true end function\nfunction invalid (input :: record{keep :: Bool value :: (n :: UInt8 where keep n)}) -> Bool is true end function"
  },
  {
    "expected": "field-predicate",
    "body": "function broken (n :: UInt8) -> (r :: Integer where r > n * n) is 0 end function\nfunction keep (n :: UInt8) -> Bool is broken n = 0 end function\nfunction invalid (input :: record{value :: (n :: UInt8 where keep n)}) -> Bool is true end function"
  },
  {
    "expected": "total",
    "body": "function keep (n :: Rational) -> Bool is true end function\nfunction invalid (input :: record{value :: (n :: UInt8 where keep (1 / 0))}) -> Bool is true end function"
  },
  {
    "expected": "total",
    "body": "function positive (n :: UInt8) -> Bool is n > 0 end function\nfunction invalid (ignored :: ()) -> record{value :: (n :: UInt8 where positive n)} is record{value = 0} end function"
  },
  {
    "expected": "definition",
    "body": "function same (left :: a) (right :: a) -> Bool requires Eq a is true end function\ntype Box (a :: Type) is a record{value :: (n :: a where same n n)} end type"
  },
  {
    "expected": "total",
    "body": "function finite (n :: Float64) -> Bool is n + 0.2 = 0.3 end function\ntype Number is a record{value :: (n :: UInt8 where finite 0.1)} end type\nfunction invalid (ignored :: ()) -> Number is Number record{value = 0} end function"
  },
  {
    "expected": "total",
    "body": "function identity (n :: a) -> a is n end function\nfunction finite (n :: Float64) -> Bool is n + 0.2 = 0.3 end function\ntype Number is a record{value :: (n :: UInt8 where finite (identity 0.1))} end type\nfunction invalid (ignored :: ()) -> Number is Number record{value = 0} end function"
  },
  {
    "expected": "total",
    "body": "type NumberKind (a :: Type) is one of | Floating of type () where a = Float64 end type\nfunction finite (kind :: NumberKind a) (n :: a) -> Bool is first matching case of kind: when Floating ignored then n + 0.2 = 0.3 end case end function\ntype Number is a record{value :: (n :: UInt8 where finite (Floating ()) 0.1)} end type\nfunction invalid (ignored :: ()) -> Number is Number record{value = 0} end function"
  }
];
  for(const machineBits of [32,64])for(const {body,expected} of invalid)for(const method of ['check','expand']) {
    const result=await compiler[method]({...options,verification:{layers:[]},machineBits,
      sources:[{path:'invalid.lawspec',content:'unit invalid\n'+body}]});
    assert.ok(result.diagnostics.length>0,body);
    assert.ok(result.diagnostics.some(row=>row.code===expected),JSON.stringify(result.diagnostics));
    assert.ok(result.diagnostics.every(row=>row.code!=='parse'&&!row.message.includes('$lawspecFieldAdmission')),JSON.stringify(result.diagnostics));
  }
});

test('predicate-backed record formatting and explanation preserve typed obligations and unselected evidence',async()=>{
  const result=await compiler.check({...options,sources});
  assert.deepEqual(result.diagnostics,[]);
  assert.ok(!JSON.stringify(result).includes('$lawspecFieldAdmission'));
  const unselected=await compiler.check({...options,verification:{layers:[]},sources});
  assert.deepEqual(unselected.diagnostics,[]);
  const laws=unselected.evidence.filter(row=>row.stage==='law');
  assert.equal(laws.length,6);
  assert.ok(laws.every(row=>row.status==='not-verified'));
  assert.equal(unselected.verification.intrinsicDefinitionChecks,true);
  const formatted=await compiler.format({...options,sources});
  assert.deepEqual(formatted.diagnostics,[]);
  const repeated=await compiler.format({...options,sources:formatted.formattedSources});
  assert.deepEqual(repeated.formattedSources,formatted.formattedSources);
  const checked=await compiler.check({...options,sources:formatted.formattedSources});
  assert.deepEqual(checked.diagnostics,[]);
  assert.deepEqual(checked.dataTypes.map(row=>row.id),result.dataTypes.map(row=>row.id));
  for(const law of result.laws)for(const view of ['developer','business','formal','evidence']) {
    const explanation=explainLaw(law,result,view);
    assert.equal(explanation.assertion,law.assertion);
    assert.deepEqual(explanation.evidence,result.evidence.filter(row=>row.declaration===law.id));
  }
});
