import assert from 'node:assert/strict';
import {test} from 'node:test';
import {existsSync} from 'node:fs';
import {mkdtemp,mkdir,writeFile,symlink,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {createCompiler} from '../api.mjs';
import {targets,templates} from '../templates.mjs';

const compiler=await createCompiler();
const options={schemaVersion:5,languageProfile:'1.0-rc.2',verification:{layers:['property']}};
const source=payload=>`unit nativeFailures

 type Message (a :: Type) is a record{value :: a} end type
 type Problem is one of | Declined of type ${payload} | Blocked end type
 charge :: Int32 -> Int32 fails with Problem
 law declined is definition: charge -1 fails with Declined _ end definition end law

end unit
`;
const request=(target,payload='record{message :: (s :: Text where s != "")}')=>({...options,target,
  sources:[{path:'failures.lawspec',content:source(payload)}],nativeBindings:{
    failures:[{native:['erlang','gleam'].includes(target)?['declined']:target==='elixir'?['Application','Declined']:['application','Declined'],
      failure:'nativeFailures::Problem::Declined'}]}});

test('native exception message products generate across every target, width and layout',async()=>{
  for(const target of targets)for(const machineBits of [32,64])for(const minify of [false,true]){
    const result=await compiler.planGeneration({...request(target,'record{detail :: Message (Message Text)}'),machineBits,minify});
    assert.deepEqual(result.diagnostics,[],`${target}/${machineBits}/${minify}`);
    assert.ok(result.files.some(file=>file.placement==='source'));
  }
});

test('native exception mappings reject payloads that need invented fields or a constructor choice',async()=>{
  for(const payload of ['UInt8','Message UInt8','record{message :: Text code :: UInt8}','Either Text Text']){
    const result=await compiler.planGeneration(request('javascript',payload));
    assert.ok(result.diagnostics.some(item=>item.code==='native-binding'),JSON.stringify(result.diagnostics));
  }
});

const dependencies=new URL('../../.integration/javascript/node_modules',import.meta.url).pathname;
test('native mapped record messages cross refinements and retain their actual text',
  {skip:!existsSync(path.join(dependencies,'fast-check'))&&'requires the JavaScript acceptance dependencies'},async()=>{
    const input=request('javascript');
    input.sources[0].content=input.sources[0].content.replace('Declined _ end definition end law','Declined record{message = _} message contains "declined" end definition end law');
    const result=await compiler.planGeneration(input);assert.deepEqual(result.diagnostics,[]);
    const root=await mkdtemp(path.join(tmpdir(),'lawspec-native-failure-products-'));
    try{
      for(const file of result.files){const destination=path.join(root,file.path);await mkdir(path.dirname(destination),{recursive:true});await writeFile(destination,file.content);}
      await symlink(dependencies,path.join(root,'node_modules'),'dir');
      await writeFile(path.join(root,'src/application.mjs'),'export class Declined extends Error {}');
      const adapter=path.join(root,'src/nativeFailures.mjs');
      const run=message=>{
        return writeFile(adapter,`import {Declined} from './application.mjs'; export function charge(){throw new Declined(${JSON.stringify(message)});}`)
          .then(()=>spawnSync(process.execPath,['--test','test/nativeFailures.lawspec.test.mjs'],{cwd:root,encoding:'utf8',env:{...process.env,NODE_TEST_CONTEXT:undefined},maxBuffer:8e6}));
      };
      let execution=await run('declined');assert.equal(execution.status,0,execution.stdout+execution.stderr);
      execution=await run('');assert.notEqual(execution.status,0);assert.match(execution.stdout+execution.stderr,/refinement|restriction|predicate/i);
      execution=await run('unrelated');assert.notEqual(execution.status,0);
      execution=await run('declined');assert.equal(execution.status,0,execution.stdout+execution.stderr);
    }finally{await rm(root,{recursive:true,force:true});}
  });


test('Rust mapped record failures validate refinements before they become a caught failure',
  {skip:!['rust','all'].includes(process.env.LAWSPEC_NATIVE_LAYOUT_TARGET)&&'requires the Rust acceptance environment'},async()=>{
    const targetRoot=await mkdtemp(path.join(tmpdir(),'lawspec-native-failure-rust-target-'));
    try{for(const machineBits of [32,64])for(const minify of [false,true]){
      const input={...request('rust'),machineBits,minify};
      input.nativeBindings={rustCrate:'lawspec_example',
        functions:[{declaration:'nativeFailures::charge',native:['crate','native_app','charge']}],
        failures:[{native:['crate','native_app','Declined'],failure:'nativeFailures::Problem::Declined'}]};
      const result=await compiler.planGeneration(input);assert.deepEqual(result.diagnostics,[]);
      const root=await mkdtemp(path.join(tmpdir(),'lawspec-native-failure-rust-'));
      try{
        for(const file of result.files){const destination=path.join(root,file.path);await mkdir(path.dirname(destination),{recursive:true});await writeFile(destination,file.content);}
        await writeFile(path.join(root,'Cargo.toml'),templates('rust')['Cargo.toml']);
        await writeFile(path.join(root,'src/lib.rs'),'include!("lawspec_modules.rs"); pub mod native_app;');
        await writeFile(path.join(root,'src/native_app.rs'),`pub struct Declined(pub String);
impl std::fmt::Debug for Declined {fn fmt(&self,f:&mut std::fmt::Formatter<'_>)->std::fmt::Result{write!(f,"{}",self.0)}}
pub fn charge(_:i32)->i32{std::panic::panic_any(Declined(std::env::var("LAWSPEC_MAPPING_MESSAGE").unwrap_or("declined".into())))}
`);
        const run=message=>spawnSync('cargo',['test','--offline','--test','nativeFailures_lawspec'],{cwd:root,encoding:'utf8',maxBuffer:16e6,
          env:{...process.env,CARGO_TARGET_DIR:targetRoot,LAWSPEC_MAPPING_MESSAGE:message}});
        let execution=run('declined');assert.equal(execution.status,0,execution.stdout+execution.stderr);
        execution=run('');assert.notEqual(execution.status,0);assert.match(execution.stdout+execution.stderr,/refinement|restriction|predicate/i);
        execution=run('declined');assert.equal(execution.status,0,execution.stdout+execution.stderr);
      }finally{await rm(root,{recursive:true,force:true});}
    }}finally{await rm(targetRoot,{recursive:true,force:true});}
  });


test('Clojure mapped record failures use resolved classes and validate nested messages',
  {skip:!['clojure','all'].includes(process.env.LAWSPEC_NATIVE_LAYOUT_TARGET)&&'requires the Clojure acceptance environment'},async()=>{
    for(const machineBits of [32,64])for(const minify of [false,true])for(const [payload,singleton] of [
      ['record{message :: (s :: Text where s != "")}',true],
      ['Message (Message (record{message :: (s :: Text where s != "")}))',true],
      ['record{message :: (s :: Text where s != "")}',false],
      ['Message (Message (record{message :: (s :: Text where s != "")}))',false],
    ]){
      const input={...request('clojure',payload),machineBits,minify};
      if(singleton)input.sources[0].content=input.sources[0].content.replace(' | Blocked','');
      const result=await compiler.planGeneration(input);assert.deepEqual(result.diagnostics,[]);
      const root=await mkdtemp(path.join(tmpdir(),'lawspec-native-failure-clojure-'));
      try{
        for(const file of result.files){const destination=path.join(root,file.path);await mkdir(path.dirname(destination),{recursive:true});await writeFile(destination,file.content);}
        await writeFile(path.join(root,'deps.edn'),templates('clojure')['deps.edn']);
        await writeFile(path.join(root,'src/nativeFailures.clj'),`(ns nativeFailures)
(defn charge [value] (throw (ex-info (System/getenv "LAWSPEC_MAPPING_MESSAGE") {:type :application/Declined})))`);
        const run=message=>spawnSync('clojure',['-M:test'],{cwd:root,encoding:'utf8',maxBuffer:16e6,
          env:{...process.env,LAWSPEC_MAPPING_MESSAGE:message}});
        let execution=run('declined');assert.equal(execution.status,0,execution.stdout+execution.stderr);
        execution=run('');assert.notEqual(execution.status,0);assert.match(execution.stdout+execution.stderr,/refinement|restriction|predicate/i);
        execution=run('declined');assert.equal(execution.status,0,execution.stdout+execution.stderr);
      }finally{await rm(root,{recursive:true,force:true});}
    }
  });
