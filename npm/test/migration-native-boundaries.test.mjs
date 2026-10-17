// Generated from templates/npm/test/migration-native-boundaries.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mkdtemp,mkdir,writeFile,rm,readdir} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {spawnSync} from 'node:child_process';
import os from 'node:os';
import path from 'node:path';
import {createCompiler} from '../api.mjs';
import {targets} from '../templates.mjs';
import {migrationReport} from '../migrate.mjs';
import {bindingDigest} from '../migration-bindings.mjs';
import {checkNativeBoundaryReceipt} from '../migration-generation.mjs';

const compiler=await createCompiler();
const options={schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]}};
const generation={cases:100,maxAttempts:10000,maxShrinks:1000,exhaustiveLimit:4096};
const sources=content=>[{path:'parcel.lawspec',content}];
const legacy='unit parcel\ntype Parcel is | Packed last :: UInt8 first :: Bool end\ncopy :: Parcel -> Parcel';
const canonical='unit parcel\ntype Parcel is one of Packed of type record{last :: UInt8 first :: Bool} end type\ncopy :: Parcel -> Parcel';
const mapping=()=>({types:[{type:'parcel::type::Parcel',native:['application','Parcel'],constructors:[{
  constructor:'Packed',native:['application','Packed'],style:'variant',fields:[
    {field:'last',path:[],argument:1,native:'tail'},
    {field:'first',path:[],argument:0,native:'head'},
  ],
}]}],functions:[{declaration:'parcel::copy',native:['application','copy']}]});
const request=(target='python')=>({...options,target,generation,from:'0.24',sources:sources(legacy),nativeBindings:mapping(),
  migrated:{...options,target,generation,sources:sources(canonical)}});
const receipt=async input=>{
  const result=await compiler.migrationGeneration(input);assert.deepEqual(result.diagnostics,[]);
  return result.migrationGeneration;
};

test('resolved boundaries compare scalar functions across all targets without upgrading native assumptions',async()=>{
  for(const target of targets){
    const input=request(target);
    const owner=['fsharp','swift','haskell','elixir'].includes(target)?'Application':'application';
    input.nativeBindings={functions:[{declaration:'parcel::copy',native:[owner,'copy']}]};
    if(target==='go'){input.nativeBindings.goImports=[{alias:owner,path:'native_boundary/application'}];
      input.nativeBindings.functions[0].native=[owner,'Copy'];}
    if(target==='rust'){input.nativeBindings.rustCrate='native_boundary';
      input.nativeBindings.functions[0].native=['crate',owner,'copy'];}
    input.sources=sources('unit parcel\ncopy :: Bool -> Bool');input.migrated.sources=input.sources;
    const evidence=await receipt(input),boundary=evidence.nativeBoundary;
    assert.equal(evidence.status,'accepted',target);
    assert.equal(boundary.status,'matched',JSON.stringify([target,boundary]));
    assert.equal(boundary.before.digest,boundary.after.digest);
    assert.equal(boundary.after.digest,bindingDigest(boundary.after.contract));
    assert.equal(boundary.nativeConformance,'not-established');
    assert.equal(boundary.lawVerification,'not-established-by-boundary-correspondence');
    assert.equal(evidence.bindingProposal.obligations.after[0].status,'assumed');
  }
});

test('grouping retains existing explicit native positions and the resolved field types',async()=>{
  const evidence=await receipt(request());
  assert.equal(evidence.status,'accepted');assert.equal(evidence.nativeBoundary.status,'matched');
  const fields=evidence.bindingProposal.proposedNativeBindings.types[0].constructors[0].fields;
  assert.deepEqual(fields,[{field:'value',path:['first'],argument:0,native:'head'},
    {field:'value',path:['last'],argument:1,native:'tail'}]);
  const before=evidence.nativeBoundary.before.contract.types[0].constructors[0].fields;
  assert.deepEqual(before.map(field=>[field.native,field.type.name]),[['head','Bool'],['tail','UInt8']]);
  assert.deepEqual(evidence.nativeBoundary.after.contract.types[0].constructors[0].fields,before);
});

test('emitter acceptance alone does not hide changed unbound generated adapter layouts',async()=>{
  const input=request();input.nativeBindings={};
  const evidence=await receipt(input);
  assert.equal(evidence.status,'accepted');assert.equal(evidence.bindingProposal.status,'matched');
  assert.equal(evidence.nativeBoundary.status,'not-established');
  assert.notEqual(evidence.nativeBoundary.before.digest,evidence.nativeBoundary.after.digest);
  assert.ok(evidence.nativeBoundary.after.contract.unmappedData.length);
  const report=await migrationReport(compiler,{version:1,targets:[{language:'python',root:'python'}]},
    {sources:input.sources});
  assert.equal(report.correspondence.targetGeneration.status,'accepted');
  assert.equal(report.correspondence.nativeBoundary.status,'not-established');
  assert.ok(report.blockers.some(reason=>reason.includes('generated adapter layouts differ')));
  assert.equal(report.validated,false);assert.deepEqual(report.filesWritten,[]);
  const unchanged=request();unchanged.nativeBindings={};
  unchanged.sources=sources('unit parcel\ntype Parcel is Parcel count :: UInt8 flag :: Bool end\ncopy :: Parcel -> Parcel');
  unchanged.migrated.sources=sources('unit parcel\ntype Parcel is a record{count :: UInt8 flag :: Bool} end type\ncopy :: Parcel -> Parcel');
  assert.equal((await receipt(unchanged)).nativeBoundary.status,'matched');
});

test('changed native call types are distinct from matching configuration',async()=>{
  const input=request();input.nativeBindings={functions:[{declaration:'parcel::copy',native:['application','copy']}]};
  input.sources=sources('unit parcel\ncopy :: Bool -> Bool');
  input.migrated.sources=sources('unit parcel\ncopy :: UInt8 -> UInt8');
  const evidence=await receipt(input);
  assert.equal(evidence.status,'accepted');assert.equal(evidence.bindingProposal.status,'matched');
  assert.equal(evidence.nativeBoundary.status,'not-established');
});

test('boundary receipt validation requires anchored generation, matching descriptors and unchanged assumptions',async()=>{
  const input=request(),evidence=await receipt(input);
  const baseline=await compiler.migrationBaseline(input);
  const after=await compiler.check({...input.migrated,migrationSnapshot:true});
  const check=(made,req=input)=>checkNativeBoundaryReceipt(baseline.migrationSemantics,after.migrationSemantics,
    req,evidence.bindingProposal,made);
  assert.equal(check(evidence).status,'matched');
  for(const mutate of [e=>{delete e.nativeBoundary;},e=>{e.nativeBoundary.version=2;},
    e=>{e.nativeBoundary.policy='other';},e=>{e.nativeBoundary.status='not-established';},
    e=>{e.nativeBoundary.assumptions=[];},e=>{e.nativeBoundary.nativeConformance='verified';},
    e=>{e.nativeBoundary.lawVerification='proved';},e=>{e.nativeBoundary.before.digest='0'.repeat(64);},
    e=>{e.nativeBoundary.after.contract.types[0].constructors[0].fields.reverse();
      e.nativeBoundary.after.digest=bindingDigest(e.nativeBoundary.after.contract);},
    e=>{e.nativeBoundary.after.contract.configuration.functions=[];
      e.nativeBoundary.after.digest=bindingDigest(e.nativeBoundary.after.contract);},
    e=>{e.nativeBoundary.after.contract.unknown=true;e.nativeBoundary.after.digest=bindingDigest(e.nativeBoundary.after.contract);},
    e=>{e.after.status='rejected';},e=>{e.bindingProposal.bindings.after='0'.repeat(64);},
  ]){const made=structuredClone(evidence);mutate(made);assert.equal(check(made).status,'not-established',mutate.toString());}
  assert.equal(check(evidence,{...input,sources:sources(legacy+'\n ')}).status,'not-established');
});

test('native exception mappings retain first-match precedence rather than sorting native class names',async()=>{
  const input=request('scala');
  input.sources=sources('unit parcel\ntype Failure is | General | Specific end\ncopy :: Bool -> Bool fails with Failure');
  input.migrated.sources=sources('unit parcel\ntype Failure is one of General | Specific end type\ncopy :: Bool -> Bool fails with Failure');
  input.nativeBindings={functions:[{declaration:'parcel::copy',native:['application','copy']}],failures:[
    {native:['java','lang','RuntimeException'],failure:'parcel::Failure::General'},
    {native:['java','lang','IllegalArgumentException'],failure:'parcel::Failure::Specific'},
  ]};
  const evidence=await receipt(input);assert.equal(evidence.status,'accepted',JSON.stringify(evidence));
  assert.equal(evidence.nativeBoundary.status,'matched');
  assert.deepEqual(evidence.bindingProposal.proposedNativeBindings.failures,input.nativeBindings.failures);
  const made=await compiler.planGeneration({...input.migrated,nativeBindings:evidence.bindingProposal.proposedNativeBindings});
  assert.deepEqual(made.diagnostics,[]);
  const emitted=made.files.filter(file=>file.placement==='source').map(file=>file.content).join('\n');
  const cases=[...emitted.matchAll(/case error: (java\.lang\.(?:RuntimeException|IllegalArgumentException))/g)].map(match=>match[1]);
  assert.deepEqual(cases.slice(0,2),['java.lang.RuntimeException','java.lang.IllegalArgumentException']);
});

const run=(command,args,options)=>{
  const result=spawnSync(command,args,{encoding:'utf8',...options});
  assert.equal(result.status,0,result.stdout+'\n'+result.stderr);
};
const localPython=new URL('../../.integration/python/.venv/bin/python',import.meta.url).pathname;
const python=process.env.LAWSPEC_PYTHON_EXECUTABLE??(existsSync(localPython)?localPython:null);
for(const target of ['python','javascript'])test(`${target} old and migrated bridges preserve explicit argument order in execution`,
  {skip:target==='python'&&python===null?'Python integration environment is not installed':false},async()=>{
    for(const machineBits of [32,64])for(const minify of [false,true]){
      const input=request(target);input.machineBits=machineBits;input.minify=minify;
      Object.assign(input.migrated,{machineBits,minify});
      const evidence=await receipt(input);assert.equal(evidence.nativeBoundary.status,'matched');
      for(const side of ['before','after']){
        const generationInput=side==='before'?{...options,from:'0.24',includeGeneration:true,target,machineBits,minify,generation,
          sources:input.sources,nativeBindings:input.nativeBindings}:{...input.migrated,
          nativeBindings:evidence.bindingProposal.proposedNativeBindings};
        const result=side==='before'?await compiler.migrationBaseline(generationInput):await compiler.planGeneration(generationInput);
        assert.deepEqual(result.diagnostics,[]);
        const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-migration-boundary-'));
        try{
          for(const file of result.files.filter(file=>file.placement==='source')){
            const destination=path.join(root,file.path);await mkdir(path.dirname(destination),{recursive:true});
            await writeFile(destination,file.content);
          }
          if(target==='python'){
            await writeFile(path.join(root,'src/application.py'),`calls=[]
class Packed:
    def __init__(self, *, head, tail): self.head,self.tail=head,tail
def copy(value):
    assert type(value.head) is bool and type(value.tail) is int
    calls.append((value.head,value.tail))
    return Packed(head=not value.head,tail=value.tail+1)
`);
            await writeFile(path.join(root,'check.py'),`from lawspec_native import _native, _canonical
from lawspec_schema import Named
from application import Packed, calls
from parcel import copy
type_=Named('parcel::type::Parcel')
logical=_native.from_native(type_,Packed(head=True,tail=7))
value=_canonical.to_native(type_,logical)
result=copy(value)
restored=_native.to_native(type_,_canonical.from_native(type_,result))
assert (restored.head,restored.tail)==(False,8)
assert calls==[(True,7)]
`);
            run(python,['check.py'],{cwd:root,env:{...process.env,PYTHONPATH:path.join(root,'src')}});
          }else{
            await writeFile(path.join(root,'src/application.mjs'),`export const calls=[];
export class Packed {constructor({head,tail}) {this.head=head;this.tail=tail;}}
export const copy=value=>{
  if(typeof value.head!=='boolean'||typeof value.tail!=='number')throw Error('swapped arguments');
  calls.push([value.head,value.tail]);return new Packed({head:!value.head,tail:value.tail+1});
};`);
            await writeFile(path.join(root,'check.mjs'),`import assert from 'node:assert/strict';
import {native,canonical} from './src/lawspec_native.mjs';
import {Named} from './src/lawspec_schema.mjs';
import {Packed,calls} from './src/application.mjs';
import {copy} from './src/parcel.mjs';
const type=new Named('parcel::type::Parcel');
const logical=native.fromNative(type,new Packed({head:true,tail:7}));
const result=copy(canonical.toNative(type,logical));
const restored=native.toNative(type,canonical.fromNative(type,result));
assert.deepEqual([restored.head,restored.tail],[false,8]);
assert.deepEqual(calls,[[true,7]]);`);
            run(process.execPath,['check.mjs'],{cwd:root});
          }
        }finally{await rm(root,{recursive:true,force:true});}
      }
    }
  });

test('Java migration retains positional constructor types in compiled native bridges',
  {skip:!['java','all'].includes(process.env.LAWSPEC_NATIVE_LAYOUT_TARGET)&&
    spawnSync('javac',['-version'],{stdio:'ignore'}).status!==0?'javac is not installed':false},async()=>{
  const collect=async root=>{
    const entries=await readdir(root,{withFileTypes:true}),found=[];
    for(const entry of entries){const file=path.join(root,entry.name);
      if(entry.isDirectory())found.push(...await collect(file));else if(file.endsWith('.java'))found.push(file);}
    return found;
  };
  for(const machineBits of [32,64])for(const minify of [false,true]){
    const input=request('java');input.machineBits=machineBits;input.minify=minify;
    input.nativeBindings.functions[0].native=['application','Operations','copy'];
    Object.assign(input.migrated,{machineBits,minify});
    const evidence=await receipt(input);assert.equal(evidence.nativeBoundary.status,'matched');
    for(const side of ['before','after']){
      const nativeBindings=side==='before'?input.nativeBindings:evidence.bindingProposal.proposedNativeBindings;
      const result=side==='before'?await compiler.migrationBaseline({...options,from:'0.24',includeGeneration:true,
        target:'java',machineBits,minify,generation,sources:input.sources,nativeBindings}):
        await compiler.planGeneration({...input.migrated,nativeBindings});
      assert.deepEqual(result.diagnostics,[]);
      const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-java-migration-boundary-'));
      try{
        for(const file of result.files.filter(file=>file.placement==='source')){
          const destination=path.join(root,file.path);await mkdir(path.dirname(destination),{recursive:true});
          await writeFile(destination,file.content);
        }
        const application={
          'application/Parcel.java':'package application; public interface Parcel {}',
          'application/Packed.java':'package application; public record Packed(boolean head, short tail) implements Parcel {}',
          'application/Operations.java':`package application;
public final class Operations {
 public static int calls=0;
 public static Parcel copy(Parcel value){calls++;var packed=(Packed)value;
  if(!packed.head()||packed.tail()!=7)throw new AssertionError("swapped native fields");
  return new Packed(false,(short)8);}
}`,
          'Check.java':`import application.*; import lawspec.runtime.*;
public class Check {
 public static void main(String[] args){
  var schema=LawSpecDataSchema.create();var symbols=new java.util.HashMap<String,Object>();
  var nativeCodec=LawSpecNativeCodecs.type0(schema,${machineBits},symbols);
  var canonical=LawSpecDataCodecs.parcelCodec(schema,${machineBits},symbols);
  var logical=nativeCodec.encode(new Packed(true,(short)7));
  var returned=Parcel.copy(canonical.decode(logical));
  var restored=(Packed)nativeCodec.decode(canonical.encode(returned));
  if(restored.head()||restored.tail()!=8||Operations.calls!=1)throw new AssertionError("native result changed");
 }
}`,
        };
        for(const [name,content] of Object.entries(application)){
          const destination=path.join(root,'src/main/java',name);await mkdir(path.dirname(destination),{recursive:true});
          await writeFile(destination,content);
        }
        run('javac',['-d','out',...await collect(path.join(root,'src'))],{cwd:root});
        run('java',['-cp','out','Check'],{cwd:root});
      }finally{await rm(root,{recursive:true,force:true});}
    }
  }
});


test('resolved handler operations, async calls and effects remain part of the native contract',async()=>{
  const ability=type=>'unit effects\nability Store is\n get :: '+type+' -> '+type+'\nend\nfetch :: Bool -> Bool uses Store';
  const fixtures=[
    [ability('Bool'),ability('Bool'),'matched',{handlers:[{ability:'effects::Store',native:['application','Store']}]}],
    [ability('Bool'),ability('UInt8'),'not-established',{handlers:[{ability:'effects::Store',native:['application','Store']}]}],
    ['unit effects\nfetch :: Bool -> Bool','unit effects\nasync fetch :: Bool -> Bool','not-established',
      {functions:[{declaration:'effects::fetch',native:['application','fetch']}]}],
    ['unit effects\nfetch :: Bool -> Bool',ability('Bool'),'not-established',
      {functions:[{declaration:'effects::fetch',native:['application','fetch']}]}],
  ];
  for(const [old,made,expected,bindings] of fixtures){
    const input=request();input.sources=sources(old);input.migrated.sources=sources(made);input.nativeBindings=bindings;
    const evidence=await receipt(input);assert.equal(evidence.status,'accepted');
    assert.equal(evidence.nativeBoundary.status,expected,JSON.stringify([old,made,evidence.nativeBoundary]));
  }
});
