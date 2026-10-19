import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {test} from 'node:test';

test('large finite Python generation retains every Int8 candidate at both widths and layouts', {timeout:200000}, () => {
  const api=new URL('../api.mjs',import.meta.url).href;
  const fixture=new URL('../../test/fixtures/canonical-smt-arithmetic.lawspec',import.meta.url).href;
  const script=`
    import assert from 'node:assert/strict';
    import {readFile} from 'node:fs/promises';
    import {createCompiler} from ${JSON.stringify(api)};
    const content=await readFile(new URL(${JSON.stringify(fixture)}),'utf8');
    const compiler=await createCompiler();
    const results=[];
    for(const machineBits of [32,64])for(const minify of [false,true]) {
      const result=await compiler.planGeneration({schemaVersion:5,languageProfile:'1.0-rc.2',
        verification:{layers:['property','examples']},machineBits,minify,target:'python',
        sources:[{path:'finite-arithmetic.lawspec',content}]});
      assert.deepEqual(result.diagnostics,[]);
      const laws=result.laws.filter(law=>law.owner==='authoring.integerArithmetic');
      assert.equal(laws.length,4);
      assert.equal(laws.reduce((total,law)=>total+law.examples.length,0),7);
      const generated=result.files.find(file=>file.path.endsWith('test_authoring_integerArithmetic_lawspec.py'));
      assert.ok(generated);
      if(minify)for(let candidate=-128;candidate<=127;candidate++)
        assert.ok(generated.content.includes('ls.convert('+candidate+', "Int8", '+machineBits+')'),
          'Missing finite candidate '+candidate);
      results.push({machineBits,minify,laws:laws.length,rows:7,completeCandidateDomain:minify});
    }
    console.log(JSON.stringify(results));
  `;
  // Isolate the compiler so a regression cannot leave its WASM scheduler
  // running after the test deadline. The source domain is never reduced.
  const child=spawnSync(process.execPath,['--input-type=module','-e',script],
    {encoding:'utf8',timeout:180000,killSignal:'SIGKILL',maxBuffer:2*1024*1024});
  assert.equal(child.error,undefined,child.error?.message+'\n'+child.stderr);
  assert.equal(child.status,0,child.stderr+'\n'+child.stdout);
  const results=JSON.parse(child.stdout);
  assert.deepEqual(results.map(({machineBits,minify})=>[machineBits,minify]),
    [[32,false],[32,true],[64,false],[64,true]]);
  assert.ok(results.filter(row=>row.minify).every(row=>row.completeCandidateDomain));
});
