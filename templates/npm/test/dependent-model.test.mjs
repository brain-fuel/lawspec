import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile, mkdtemp, mkdir, writeFile, rm} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {Model, checkModelAsync, DataValue} from '../../runtime/lawspec_runtime.mjs';
import {createCompiler} from '../api.mjs';
import {programTargets} from '../templates.mjs';

const spec = '(machine stack linear) (start (indices 0) (arguments (unit))) ' +
  '(command push (arguments) (state 0) (unit true) (when false) (needs (atleast 0)) (shifts (by 1)) (key none) (restart false)) ' +
  '(command choose (arguments (dependent (int Int8 0 127) (>= 0) (< (index 0)))) (state 0) (unit false) (when false) (needs (atleast 0)) (shifts (by 0)) (key none) (restart false)) ' +
  '(command clear (arguments) (state 0) (unit true) (when false) (needs (atleast 0)) (shifts (to 0)) (key none) (restart false)) (abstract false) (invariants)';
function machine(observed, mutant=false) {
  return new Model(spec,[()=>0n,()=>0n],[
    [(s,n)=>new DataValue('flow',[n+1n]),(s,n)=>n+1n,null],
    [(s,n,i)=>{assert.ok(i>=0n && i<n,`invalid argument ${i} for ${n}`); observed.push([String(n),String(i)]); return new DataValue('flow',[i+(mutant?1n:0n),n]);},
      (s,i,n)=>new DataValue('Pair',[i,n]),null],
    [(s,n)=>new DataValue('flow',[0n]),()=>0n,null],
  ]);
}
test('dependent sampled generation replays and shrinking never executes an invalid suffix',async()=>{
  const first=[], replay=[];
  await checkModelAsync(machine(first),{seed:12n,cases:100});
  await checkModelAsync(machine(replay),{seed:12n,cases:100});
  assert.ok(first.length>100);assert.deepEqual(first,replay);
  await assert.rejects(checkModelAsync(machine([],true),{seed:12n,cases:100}),/push\(\); choose\(0\).*model returns 0/);
});
test('a rejected dependent generation attempt remains incomplete',async()=>{
  const model=machine([]);
  model.commands[1].reference=()=>{throw new Error('bounded miss');};
  await assert.rejects(checkModelAsync(model,{seed:12n,cases:100}),/incomplete model generation/);
});
test('Python and JavaScript draw and replay the same dependent domains',async()=>{
  const expected=[];await checkModelAsync(machine(expected),{seed:12n,cases:100});
  const script=`import sys,json
sys.path.insert(0,sys.argv[1])
import lawspec_runtime as ls
observed=[]
def choose(s,n,i):
    assert 0 <= i < n
    observed.append([str(n),str(i)])
    return ls.DataValue('flow',[i,n])
model=ls.Model(sys.argv[2],(lambda *a:0,lambda *a:0),[
    (lambda s,n:ls.DataValue('flow',[n+1]),lambda s,n:n+1,None),
    (choose,lambda s,i,n:ls.DataValue('Pair',[i,n]),None),
    (lambda s,n:ls.DataValue('flow',[0]),lambda *a:0,None)])
ls.check_model(model,seed=12,cases=100)
print(json.dumps(observed))
`;
  const result=spawnSync(process.env.LAWSPEC_PYTHON??'python3',['-B','-c',script,new URL('../../runtime/',import.meta.url).pathname,spec],{encoding:'utf8'});
  assert.equal(result.status,0,result.stderr);assert.deepEqual(JSON.parse(result.stdout),expected);
});
test('all program targets carry dependent domains through the existing model syntax',async()=>{
  const compiler=await createCompiler();
  const content=await readFile(new URL('../../test/fixtures/dependent-model-arguments.lawspec',import.meta.url),'utf8');
  for(const target of programTargets){
    const result=await compiler.planGeneration({languageProfile:'1.0-rc.2',target,verification:{layers:['model']},sources:[{path:'dependent.lawspec',content}]});
    assert.deepEqual(result.diagnostics,[],target);
    assert.ok(result.files.some(file=>file.content.includes('(dependent')),target);
  }
});
test('generated JavaScript executes a real indexed adapter and shrinks its result mutant',async()=>{
  const compiler=await createCompiler();
  const content=await readFile(new URL('../../test/fixtures/dependent-model-arguments.lawspec',import.meta.url),'utf8');
  const result=await compiler.planGeneration({languageProfile:'1.0-rc.2',target:'javascript',verification:{layers:['model']},sources:[{path:'dependent.lawspec',content}]});
  assert.deepEqual(result.diagnostics,[]);
  const root=await mkdtemp(path.join(tmpdir(),'lawspec-dependent-native-'));
  try {
    for(const file of result.files){const target=path.join(root,file.path);await mkdir(path.dirname(target),{recursive:true});await writeFile(target,file.content);}
    const adapter=path.join(root,'src/example/dependentModel.mjs');
    const implementation=`import {StackEmpty,StackPush,PushDetails,PushFlow,ChooseAtFlow,ClearFlow} from '../lawspec_data.mjs';
export const empty = () => new StackEmpty();
export const push = state => new PushFlow(new StackPush(new PushDetails(state,0n)));
export const chooseAt = (state,i) => new ChooseAtFlow(i,state);
export const clear = () => new ClearFlow(new StackEmpty());
`;
    const run=()=>spawnSync(process.execPath,['--test',path.join(root,'test/example_dependentModel.lawspec.test.mjs')],{encoding:'utf8',env:{...Object.fromEntries(Object.entries(process.env).filter(([key])=>key!=='NODE_TEST_CONTEXT')),LAWSPEC_SEED:'12'},timeout:30000});
    await writeFile(adapter,implementation);
    const good=run();assert.equal(good.status,0,good.stdout+good.stderr);assert.match(good.stdout,/tests 1/);
    await writeFile(adapter,implementation.replace('ChooseAtFlow(i,state)','ChooseAtFlow(i+1,state)'));
    const bad=run();assert.equal(bad.status,1,bad.stdout+bad.stderr);assert.match(bad.stdout+bad.stderr,/the model returns 0/);
  } finally {await rm(root,{recursive:true,force:true});}
});
