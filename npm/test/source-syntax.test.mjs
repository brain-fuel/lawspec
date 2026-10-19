// Generated from templates/npm/test/source-syntax.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {createCompiler} from '../api.mjs';

const canonical={schemaVersion:5,languageProfile:'1.0-rc.2',verification:{layers:[]}};
const source={path:'templates.lawspec',content:`unit templates
-- handler fake for Ability is end
function identity (value :: a) -> a is value end function
law same (operation :: a -> a) requires Eq a is
  definition: for all (value :: a) => operation value = value end for all end definition
end law
end unit
`};

test('unused templates are checked without inventing executable specializations or law evidence',async()=>{
  const compiler=await createCompiler();
  for(const machineBits of [32,64]) {
    const result=await compiler.check({...canonical,machineBits,sources:[source]});
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.verification.selection,'no-selected-checks');
    assert.equal(result.verification.intrinsicDefinitionChecks,true);
    assert.deepEqual(result.definitions,[]);
    assert.deepEqual(result.laws,[]);
  }
});

test('warm requests retain mandatory definition checks and explicit unverified law evidence',async()=>{
  const compiler=await createCompiler();
  const input={...canonical,sources:[source]};
  const first=await compiler.check(input);
  assert.deepEqual(first.diagnostics,[]);
  assert.deepEqual(await compiler.check(input),first);
  const invalid=await compiler.check({...input,sources:[{path:'invalid.lawspec',content:
    'unit invalid\nfunction invalid (unused :: a) -> Integer is 1 / 0 end function\nend unit'}]});
  assert.ok(invalid.diagnostics.some(d=>d.code==='total'));
  const unselected=await compiler.check({...input,sources:[{path:'false.lawspec',content:
    'unit selected\nlaw falseClaim is definition: false end definition end law\nend unit'}]});
  assert.deepEqual(unselected.diagnostics,[]);
  assert.equal(unselected.evidence.find(item=>item.stage==='law').status,'not-verified');
});

test('standalone harnesses require their own named groups and close independently of units',async()=>{
  const compiler=await createCompiler();
  const sources=[{path:'unit.lawspec',content:`unit configured
f :: Bool -> Bool
law identity is definition: for all (value :: Bool) => f value = value end for all end definition end law
end unit`},{path:'harness.lawspec',content:`harness settings for configured is
for law identity
  label if value then "enabled" else "disabled" end if
end for law
end harness`}];
  assert.deepEqual((await compiler.check({...canonical,sources})).diagnostics,[]);
  const broken=await compiler.check({...canonical,sources:[sources[0],{...sources[1],
    content:sources[1].content.replace('end for law','end harness')}]});
  assert.equal(broken.diagnostics[0].code,'block-close-mismatch');
  assert.equal(broken.diagnostics[0].span.start.file,'harness.lawspec');
  assert.equal(broken.diagnostics[0].span.start.line,4);
  assert.equal(broken.diagnostics[0].related[0].span.start.line,2);
});
