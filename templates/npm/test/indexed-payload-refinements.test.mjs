import {extendUnit} from './compiler-input.mjs';
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {existsSync} from 'node:fs';
import {mkdtemp,mkdir,writeFile,symlink,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {createCompiler} from '../api.mjs';
import {programTargets as targets} from '../templates.mjs';

const compiler=await createCompiler();
const options={schemaVersion:5,languageProfile:'1.0-rc.2',verification:{layers:[]}};
const source=`unit refinementFacts

type Vec (n :: Whole) (a :: Type) is one of
  | VNil where n = 0
  | VCons of type record{head :: a tail :: Vec m a} where n = m + 1
end type
function concatV (xs :: Vec n Nat) (ys :: Vec m Nat) -> Vec (n + m) Nat is
  first matching case of xs:
    when VNil then ys
    when VCons record{head = h, tail = t} then VCons record{head = h, tail = concatV t ys}
  end case
end function
function values (xs :: Vec n Nat) -> List Nat is
  first matching case of xs:
    when VNil then []
    when VCons record{head = h, tail = t} then Cons h (values t)
  end case
end function

end unit
`;
const inputs=[[],[1],[2],[1,1],[1,2],[2,1],[2,2]];
const vector=values=>values.length?`(VCons record{head = ${values[0]}, tail = ${vector(values.slice(1))}})`:'VNil';
function matrix(mutant=false){
  let index=0;
  return extendUnit(source,inputs.flatMap(left=>inputs.map(right=>{
    const row=index++,expected=mutant&&row===1?[3]:[...left,...right];
    return `law matrix${row} is definition: values (concatV ${vector(left)} ${vector(right)}) must be [${expected.join(', ')}] end definition end law
`;
  })).join('\n'));
}
const sources=content=>[{path:'refinements.lawspec',content}];

test('indexed product payloads preserve positive refinements independently of optional law checks',async()=>{
  for(const machineBits of [32,64]){
    const result=await compiler.check({...options,machineBits,sources:sources(source)});
    assert.deepEqual(result.diagnostics,[]);
    for(const replacement of ['concatV t ys','VCons record{head = h, tail = ys}',
      'VCons record{head = 0, tail = concatV t ys}','concatV xs ys']){
      const wrong=source.replace('VCons record{head = h, tail = concatV t ys}',replacement);
      const rejected=await compiler.check({...options,machineBits,sources:sources(wrong)});
      assert.ok(rejected.diagnostics.some(item=>item.code==='total'),JSON.stringify(rejected.diagnostics));
    }
    assert.deepEqual(await compiler.check({...options,machineBits,sources:sources(source)}),result);
  }
});

test('49 independent positive-vector outcomes are completely checked at both machine widths',async()=>{
  for(const machineBits of [32,64]){
    const result=await compiler.check({...options,verification:{layers:['exhaustive']},machineBits,sources:sources(matrix())});
    assert.deepEqual(result.diagnostics,[]);
    const evidence=result.evidence.filter(item=>item.stage==='law'&&item.declaration.startsWith('refinementFacts::law::matrix'));
    assert.equal(evidence.length,49);
    assert.ok(evidence.every(item=>item.status==='exhaustively-checked'));
    const wrong=await compiler.check({...options,verification:{layers:['exhaustive']},machineBits,sources:sources(matrix(true))});
    assert.ok(wrong.diagnostics.some(item=>item.code==='refuted'));
  }
});

test('checked indexed definitions generate for all targets, machine widths and layouts',async()=>{
  for(const machineBits of [32,64])for(const minify of [false,true])for(const target of targets){
    const result=await compiler.planGeneration({...options,machineBits,minify,target,sources:sources(source)});
    assert.deepEqual(result.diagnostics,[],`${target}/${machineBits}/${minify}`);
    assert.ok(result.files.some(file=>file.placement==='source'));
  }
});

const dependencies=new URL('../../.integration/javascript/node_modules',import.meta.url).pathname;
test('generated JavaScript executes all independent outcomes and rejects a changed expectation',
  {skip:!existsSync(path.join(dependencies,'fast-check'))&&'requires the JavaScript acceptance dependencies'},async()=>{
    const request={...options,target:'javascript',verification:{layers:['property']}};
    const correct=await compiler.planGeneration({...request,sources:sources(matrix())});
    const mutant=await compiler.planGeneration({...request,sources:sources(matrix(true))});
    assert.deepEqual(correct.diagnostics,[]);assert.deepEqual(mutant.diagnostics,[]);
    const root=await mkdtemp(path.join(tmpdir(),'lawspec-indexed-refinements-'));
    try{
      const stage=async result=>{for(const file of result.files){
        const destination=path.join(root,file.path);await mkdir(path.dirname(destination),{recursive:true});
        await writeFile(destination,file.content);
      }};
      await writeFile(path.join(root,'package.json'),JSON.stringify({type:'module'}));
      await symlink(dependencies,path.join(root,'node_modules'),'dir');
      const files=correct.files.filter(file=>file.path.endsWith('.lawspec.test.mjs')).map(file=>file.path);
      assert.equal(files.length,1);
      const env={...process.env,LAWSPEC_SEED:'42'};delete env.NODE_TEST_CONTEXT;
      const run=()=>spawnSync(process.execPath,['--test',...files],{cwd:root,env,encoding:'utf8',maxBuffer:16*1024*1024});
      await stage(correct);const passed=run();assert.equal(passed.status,0,passed.stdout+passed.stderr);
      for(let index=0;index<49;index++)assert.match(passed.stdout,new RegExp(`refinementFacts::matrix${index} `));
      await stage(mutant);const failed=run();assert.notEqual(failed.status,0,failed.stdout+failed.stderr);
      assert.match(failed.stdout,/refinementFacts::matrix1 /);
      await stage(correct);const restored=run();assert.equal(restored.status,0,restored.stdout+restored.stderr);
    }finally{await rm(root,{recursive:true,force:true});}
  });

test('wrapper bounds prove only with proof selected and retain boundary counterexamples',async()=>{
  const wrapper=({minimum=1,lower=1,upper=1000,boundary=1000}={})=>`unit wrapperFacts

wrapper Quantity is Int32 where value >= ${minimum} and value <= 1000 end wrapper
law bounds is
  definition: for all (quantity :: Quantity) =>
    valueOfQuantity quantity >= ${lower} and valueOfQuantity quantity <= ${upper}
  end for all end definition
  example boundary:
    quantity = Quantity ${boundary}
    expect valueOfQuantity quantity = ${boundary}
  end example
end law

end unit
`;
  const check=(machineBits,layers,content)=>compiler.check({...options,machineBits,verification:{layers},sources:sources(content)});
  for(const machineBits of [32,64]){
    const unselected=await check(machineBits,[],wrapper());assert.deepEqual(unselected.diagnostics,[]);
    assert.equal(unselected.evidence.find(item=>item.stage==='law').status,'not-verified');
    const proved=await check(machineBits,['proof'],wrapper());assert.deepEqual(proved.diagnostics,[]);
    assert.equal(proved.evidence.find(item=>item.stage==='law').status,'proved');
    for(const variant of [{lower:2,boundary:1},{upper:999,boundary:1000},{minimum:0,boundary:0}]){
      const unknown=await check(machineBits,['proof'],wrapper(variant));assert.deepEqual(unknown.diagnostics,[]);
      assert.notEqual(unknown.evidence.find(item=>item.stage==='law').status,'proved');
      const planned=await check(machineBits,['examples'],wrapper(variant));assert.deepEqual(planned.diagnostics,[]);
      assert.equal(planned.evidence.find(item=>item.stage==='law').status,'planned');
      const witness=extendUnit(wrapper(variant),`\nlaw boundaryWitness is definition:
        valueOfQuantity (Quantity ${variant.boundary}) >= ${variant.lower??1} and
        valueOfQuantity (Quantity ${variant.boundary}) <= ${variant.upper??1000}
      end definition end law
`);
      const refuted=await check(machineBits,['exhaustive'],witness);
      assert.ok(refuted.diagnostics.some(item=>item.code==='refuted'));
    }
  }
});
