// Generated from templates/npm/test/model-layer-selection.test.mjs by lawspec-dev generate. Do not edit.
// Native binding regeneration must honor optional model execution without
// removing the program's public stateful APIs or ordinary law checks.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {createCompiler} from '../api.mjs';
import {programTargets as targets} from '../templates.mjs';
const compiler=await createCompiler();
const content=await readFile(new URL('../../test/fixtures/canonical-model-layer-selection.lawspec',import.meta.url),'utf8');
const adapters=['openAccount','deposit','withdrawAll','balance','close','reopen','depositTwice','survivesCrash'];
function bindings(target){
  return {...(target==='rust'?{rustCrate:'lawspec_example'}:{}),functions:adapters.map(name=>({
    declaration:'example.actors::'+name,native:target==='go'?[name[0].toUpperCase()+name.slice(1)]:
      target==='haskell'?['Application',name]:target==='rust'?['crate','application',name]:['application',name]}))};
}
const model=entry=>entry.law.includes('::model::')||entry.law.endsWith('::supervision');
const sources=result=>result.files.filter(file=>file.placement==='source').map(file=>[file.path,file.content,file.ownership]);
test('native binding regeneration preserves actor APIs and independently selected law and model checks on all targets',async()=>{
  for(const target of targets)for(const [machineBits,minify]of [[32,false],[64,true]]){
    const request={schemaVersion:5,languageProfile:'1.0-rc.2',target,machineBits,minify,
      sources:[{path:'actors.lawspec',content}],nativeBindings:bindings(target)};
    const disabled=await compiler.planGeneration({...request,verification:{layers:['property','examples']}});
    const enabled=await compiler.planGeneration({...request,verification:{layers:['property','examples','model']}});
    assert.deepEqual(disabled.diagnostics,[],target);assert.deepEqual(enabled.diagnostics,[],target);
    assert.equal(disabled.tests.filter(model).length,0,target);
    assert.equal(disabled.tests.length,2,target);assert.equal(enabled.tests.filter(model).length,5,target);
    const laws=enabled.tests.filter(entry=>!model(entry));
    // API.verificationKeys deliberately hashes the entire verification selection
    // into each key. Check that change explicitly while preserving every slot field.
    for(let index=0;index<laws.length;index++)assert.notEqual(laws[index].key,disabled.tests[index].key,target);
    const slots=entries=>entries.map(({key,...entry})=>entry);
    assert.deepEqual(slots(laws),slots(disabled.tests),target);
    assert.deepEqual(sources(enabled),sources(disabled),target+' public sources changed with model selection');
  }
});
