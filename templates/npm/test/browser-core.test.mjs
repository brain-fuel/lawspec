import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile,writeFile,mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

test('the browser WASI reactor initializes with the shared heap policy and checks actual source',async()=>{
  const directory=await mkdtemp(path.join(tmpdir(),'lawspec-browser-core-'));
  const fetch=globalThis.fetch;
  try {
    const [template,partial,glue,wasm]=await Promise.all([
      readFile(new URL('../../templates/site/lawspec-core.mjs',import.meta.url),'utf8'),
      readFile(new URL('../../templates/partials/core-instance.mjs',import.meta.url),'utf8'),
      readFile(new URL('../core_jsffi.js',import.meta.url)),
      readFile(new URL('../core.wasm',import.meta.url)),
    ]);
    assert.equal(template.split('//@ partial-core-instance').length,2);
    await writeFile(path.join(directory,'core.mjs'),template.replace('//@ partial-core-instance',partial));
    await writeFile(path.join(directory,'core_jsffi.js'),glue);
    globalThis.fetch=async url=>{
      assert.equal(String(url),'https://lawspec.invalid/core.wasm');
      return new Response(wasm,{headers:{'content-type':'application/wasm'}});
    };
    const browser=await import(pathToFileURL(path.join(directory,'core.mjs')));
    const compiler=await browser.createCompiler(new URL('https://lawspec.invalid/core.wasm'));
    const content=`unit browser
function same (value :: Integer) -> Integer is value end function
law same is definition: true end definition end law
end unit
`;
    const input={schemaVersion:5,languageProfile:'1.0-rc.2',verification:{layers:[]},
      sources:[{path:'browser.lawspec',content}]};
    const result=await compiler.check(input);
    assert.deepEqual(result.diagnostics,[]);
    assert.equal(result.verification.intrinsicDefinitionChecks,true);
    assert.equal(result.verification.selection,'no-selected-checks');
    const invalid=await compiler.check({...input,sources:[{path:'browser.lawspec',
      content:content.replace('is value end function','is prelude.quot value 0 end function')}]});
    assert.ok(invalid.diagnostics.length);
    assert.ok(invalid.diagnostics.every(d=>d.code!=='parse'&&!d.code.startsWith('block-')));
  } finally {
    globalThis.fetch=fetch;
    await rm(directory,{recursive:true,force:true});
  }
});
