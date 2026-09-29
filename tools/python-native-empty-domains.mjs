// A phantom parameter can be empty; sampling that parameter still cannot succeed.
import assert from 'node:assert/strict';
import {execFileSync,spawnSync} from 'node:child_process';
import {mkdir,writeFile,readFile,rm} from 'node:fs/promises';
import path from 'node:path';
import {createCompiler} from '../npm/api.mjs';
const root=path.resolve(import.meta.dirname,'..');
const compiler=process.env.LAWSPEC_CORE;
assert.ok(compiler,'Set LAWSPEC_CORE');
const wasm=await createCompiler();
const source=await readFile(path.join(root,'test/fixtures/native_empty_domains.lawspec'),'utf8');
for(const machineBits of [32,64]) for(const minify of [false,true]){
  const directory=path.join(root,'.artifacts/python-native-empty-domains',`${machineBits}-${minify}`);
  await rm(directory,{recursive:true,force:true});
  await mkdir(directory,{recursive:true});
  const request={schemaVersion:4,method:'planGeneration',target:'python',machineBits,minify,
    sourceDir:'library',testDir:'checks',generation:{exhaustiveLimit:1},
    sources:[{path:'empty.lawspec',content:source}],nativeBindings:{types:[
      {type:'example.empty::type::Phantom',native:['domain','Wrapped'],constructors:[
        {constructor:'Phantom',native:['domain','Wrapped'],style:'record',fields:[{field:'value',native:'payload'}]}]}],
    generators:[{type:'example.empty::type::Phantom',factory:['factories','phantoms']},
      {type:'List',factory:['factories','lists']}]}};
  const result=JSON.parse(execFileSync(compiler,[],{input:JSON.stringify(request),encoding:'utf8',maxBuffer:32*1024*1024}));
  assert.deepEqual(result.diagnostics,[]);
  assert.deepEqual(await wasm.planGeneration(request),result);
  const put=async(file,content)=>{const dest=path.join(directory,file);await mkdir(path.dirname(dest),{recursive:true});await writeFile(dest,content);};
  for(const file of result.files) await put(file.path,file.content);
  await put('library/domain.py','from dataclasses import dataclass\n\n\n@dataclass\nclass Wrapped:\n    payload: int\n');
  const factories=`from hypothesis import strategies as st
from domain import Wrapped

samples = 0


def wrap(value):
    global samples
    samples += 1
    return Wrapped(value)


def phantoms(unused):
    return st.integers(40, 100).map(wrap)


def lists(child):
    raise AssertionError("finite List Empty must be enumerated")
`;
  await put('checks/factories.py',factories);
  await put('checks/conftest.py',`import pytest
import factories


@pytest.fixture(scope="session", autouse=True)
def sampled_phantom():
    yield
    assert factories.samples > 0
`);
  const env={...process.env,PYTHONDONTWRITEBYTECODE:'1',PYTHONPATH:
    [path.join(directory,'library'),path.join(directory,'checks'),
      process.env.LAWSPEC_PYTHON_DEPS ?? path.join(root,'.artifacts/python-data-deps')].join(path.delimiter)};
  const run=()=>spawnSync(process.env.LAWSPEC_PYTHON ?? 'python3.13',['-B','-m','pytest','-q','--tb=short','checks'],
    {cwd:directory,env,encoding:'utf8',maxBuffer:32*1024*1024});
  const correct=run();
  await put('correct.log',correct.stdout+correct.stderr);
  assert.equal(correct.status,0,correct.stdout+correct.stderr);
  await put('checks/factories.py',factories.replace('st.integers(40, 100).map(wrap)','unused.map(wrap)'));
  await put('checks/conftest.py','');
  const impossible=run();
  await put('impossible.log',impossible.stdout+impossible.stderr);
  assert.notEqual(impossible.status,0);
  assert.match(impossible.stdout+impossible.stderr,/Unsatisfiable|Cannot generate examples/);
  console.log(`Python ${machineBits}, minify=${minify}: ignored Empty parameter works; demanded Empty fails; List Empty enumerated`);
}
