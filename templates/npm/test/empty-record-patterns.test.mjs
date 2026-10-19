import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';

const compiler=await createCompiler();
const content=await readFile(new URL('../../test/fixtures/canonical-empty-record-patterns.lawspec',import.meta.url),'utf8');
const sources=[{path:'empty-patterns.lawspec',content}];
const options={schemaVersion:5,languageProfile:'1.0-rc.2',verification:{layers:['exhaustive','examples']}};
const targets=['java','python','javascript','typescript','go','haskell','kotlin','rust','erlang','elixir','gleam','fsharp','csharp','scala','groovy','clojure','swift'];

test('typed empty patterns preserve empty, populated, nominal, generic and nested record outcomes on every target',async()=>{
  for(const machineBits of [32,64]) {
    const result=await compiler.check({...options,machineBits,sources});
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.laws.length,7);
    assert.equal(result.laws.reduce((n,law)=>n+law.examples.length,0),16);
    assert.ok(result.evidence.filter(row=>row.stage==='law').every(row=>row.status==='exhaustively-checked'));
    for(const target of targets)for(const minify of [false,true]) {
      const generated=await compiler.planGeneration({...options,machineBits,sources,target,minify});
      assert.deepEqual(generated.diagnostics,[],target+' '+machineBits+' '+minify);
      assert.ok(generated.files.length>0);
    }
  }
});

test('empty patterns do not admit scalars, collections, sums or unknown type variables',async()=>{
  for(const type of ['Integer','Bool','List Bool','()','Maybe Bool','a']) {
    const result=await compiler.check({...options,verification:{layers:[]},sources:[{path:'invalid.lawspec',content:
      'unit invalid\nfunction invalid (value of type '+type+') -> Bool is first matching case of value: when record{} then true end case end function\nend unit\n'}]});
    assert.ok(result.diagnostics.some(diagnostic=>diagnostic.message.includes('empty record pattern requires a known record type')),type);
  }
});

test('empty patterns retain guard exhaustiveness and mandatory definition checks with no law layers',async()=>{
  for(const content of [
    `function invalid (value of type record{flag of type Bool}) -> Bool is first matching case of value: when record{} if value.flag then true end case end function
`,
    `function invalid (value of type Integer) -> Bool is first matching case of record{field = 1 / value}: when record{} then true end case end function
`,
  ]) {
    const result=await compiler.check({...options,verification:{layers:[]},sources:[{path:'invalid.lawspec',content:'unit invalid\n'+content+'\nend unit\n'}]});
    assert.ok(result.diagnostics.length>0);
    assert.ok(result.diagnostics.some(diagnostic=>/non-exhaustive|nonzero denominator/.test(diagnostic.message)));
  }
});

test('empty record pattern formatting is idempotent and retains typed outcomes',async()=>{
  const first=await compiler.format({...options,sources});
  assert.deepEqual(first.diagnostics,[]);
  assert.ok(first.formattedSources[0].content.includes('when record{}'));
  const second=await compiler.format({...options,sources:first.formattedSources});
  assert.deepEqual(second.diagnostics,[]);
  assert.deepEqual(second.formattedSources,first.formattedSources);
  const checked=await compiler.check({...options,sources:first.formattedSources});
  assert.deepEqual(checked.diagnostics,[]);
});
