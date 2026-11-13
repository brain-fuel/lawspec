import {semanticFacts} from './compiler-input.mjs';
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';

import {foldingChecks} from './case-fold-checks.mjs';

test('pinned full Unicode folding preserves author names, scope and mandatory checks through the WASM API',()=>foldingChecks(64));

test('the complete upstream mapping corpus and picture examples retain checked behavior through formatting',async()=>{
  const compiler=await createCompiler();
  const paths=['examples/rc1/picture-tuples.lawspec','examples/rc1/picture-records.lawspec',
    'examples/rc1/banner-filenames.lawspec','test/fixtures/canonical-unicode-casefold.lawspec'];
  const sources=await Promise.all(paths.map(async path=>({path,
    content:await readFile(new URL('../../'+path,import.meta.url),'utf8')})));
  const input={schemaVersion:5,languageProfile:'1.0-rc.2',verification:{layers:['property','examples']},sources};
  const before=await compiler.check({...input});assert.deepEqual(before.diagnostics,[]);
  const formatted=await compiler.format(input);assert.deepEqual(formatted.diagnostics,[]);
  const after=await compiler.check({...input,sources:formatted.formattedSources});
  assert.deepEqual(after.diagnostics,[]);

  assert.deepEqual(semanticFacts(after),semanticFacts(before));
  const twice=await compiler.format({...input,sources:formatted.formattedSources});assert.deepEqual(twice.diagnostics,[]);
  assert.deepEqual(twice.formattedSources,formatted.formattedSources);
  const declarations=before.laws.filter(law=>!law.id.startsWith('lawspec.'));
  assert.equal(declarations.length,4);
  assert.equal(declarations.flatMap(law=>law.examples).length,18);
});
