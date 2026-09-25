// Follow transitive local imports so a convenience module cannot hide inference.
import {readFile} from 'node:fs/promises';
import assert from 'node:assert/strict';
const forbidden=new Set(['Model','Parser','Compile','Frontend','Refinement','Domain','Eval','Public','Api']);
const roots=['Core','Core.Validate','Core.Eval','Core.Semantics','Testing','Backend','CoreEmit','RustEmit','CoreScalarEmit','CoreNativeScalarEmit'];
const seen=new Set();
async function visit(name,trail=[]){
 assert.ok(!forbidden.has(name),`Core/backend boundary violation: ${[...trail,name].join(' -> ')}`);
 if(seen.has(name))return;
 seen.add(name);
 const source=await readFile(new URL(`../src/LawSpec/${name.replaceAll('.','/')}.hs`,import.meta.url),'utf8');
 for(const match of source.matchAll(/^import\s+(?:qualified\s+)?LawSpec\.([A-Za-z0-9.]+)/gm))await visit(match[1],[...trail,name]);
}
for(const root of roots)await visit(root);
console.log(`Core and all eight emitters: ${seen.size} modules satisfy the syntax/inference boundary.`);
