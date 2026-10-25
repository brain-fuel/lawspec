// Generated from templates/npm/test/finite-generation.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {test} from 'node:test';
import {fileURLToPath} from 'node:url';

test('large finite Python generation retains every Int8 candidate at both widths and layouts', {timeout:200000}, () => {
  const api=new URL('../api.mjs',import.meta.url).href;
  const fixture=new URL('../../test/fixtures/canonical-smt-arithmetic.lawspec',import.meta.url).href;
  const python=process.env.LAWSPEC_PYTHON ?? fileURLToPath(new URL('../../.integration/python/.venv/bin/python',import.meta.url));
  const script=`
    import assert from 'node:assert/strict';
    import {readFile,mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
    import {spawnSync} from 'node:child_process';
    import {tmpdir} from 'node:os';
    import path from 'node:path';
    import {createCompiler} from ${JSON.stringify(api)};
    const content=await readFile(new URL(${JSON.stringify(fixture)}),'utf8');
    const compiler=await createCompiler();
    const results=[];
    const folder=await mkdtemp(path.join(tmpdir(),'lawspec-finite-byte-'));
    try {
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
      const project=path.join(folder,machineBits+'-'+minify);
      for(const file of result.files) {
        const destination=path.join(project,file.path);
        await mkdir(path.dirname(destination),{recursive:true});
        await writeFile(destination,file.content);
      }
      const observe=${JSON.stringify(`import lawspec_runtime as ls
import test_authoring_integerArithmetic_lawspec as checks

expected = list(range(-128, 128))
observed = []
original = ls.search_elements

def search(universal, values, predicate):
    values = list(values)
    visited = []
    def check(value):
        visited.append(value)
        return predicate(value)
    result = original(universal, values, check)
    observed.append((values, visited))
    return result

ls.search_elements = search
checks._assert_no_integer_has_a_negative_square("complete byte domain", {})
assert observed == [(expected, expected)], observed
`)};
      const executed=spawnSync(${JSON.stringify(python)},['-B','-c',observe],{cwd:project,encoding:'utf8',
        env:{...process.env,PYTHONPATH:[path.join(project,'src'),path.join(project,'tests'),process.env.PYTHONPATH].filter(Boolean).join(path.delimiter)}});
      assert.equal(executed.error,undefined,executed.error?.message);
      assert.equal(executed.status,0,executed.stderr+'\\n'+executed.stdout);
      results.push({machineBits,minify,laws:laws.length,rows:7,completeCandidateDomain:true});
    }
    } finally { await rm(folder,{recursive:true,force:true}); }
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
  assert.ok(results.every(row=>row.completeCandidateDomain));
});
