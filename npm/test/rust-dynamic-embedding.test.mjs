// Generated from templates/npm/test/rust-dynamic-embedding.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mkdtemp,mkdir,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {createCompiler} from '../api.mjs';
import {templates} from '../templates.mjs';

const compiler=await createCompiler();
const source=`unit example.dynamicEmbedding
 type Refusal is one of | Negative | Blocked end type
 type State is a record{balance :: Float64 entries :: KeyVal Text Float64} end type
 function empty (u :: Unit) -> State is State record{balance = 0.0, entries = prelude.keyValOf []} end function
 ability Ledger is
   add :: Float64 -> Float64 fails with Refusal
 end ability
 procedure credit (amount :: Float64) (state :: State) -> Pair Float64 State fails with Refusal is
   if amount < 0.0 then raise Negative else
     let next = state.balance + amount in
     Pair next (state with balance = next, entries = prelude.put "last" amount state.entries)
     end let
   end if
 end procedure
 handler account for Ledger with state current :: State start empty unitValue is
   operation add by credit end operation
 end handler
 end unit
`;
const generate=(content,machineBits,minify)=>compiler.planGeneration({schemaVersion:5,languageProfile:'1.0-rc.2',
  verification:{layers:[]},target:'rust',machineBits,minify,sources:[{path:'ledger.lawspec',content}],
  nativeBindings:{rustCrate:'lawspec_example'}});

test('Rust dynamic handlers expose construction, failures and native state snapshots',async()=>{
  for(const machineBits of [32,64])for(const minify of [false,true]){
    const result=await generate(source,machineBits,minify);
    assert.deepEqual(result.diagnostics,[]);
    const abilities=result.files.find(file=>file.path==='src/lawspec_abilities.rs').content;
    assert.match(abilities,/Mutex<Option<ls::Value>>/);
    for(const name of ['start','try_add','state','set_state'])assert.ok(abilities.includes(`pub fn ${name}(`),name);
  }
});

test('Rust dynamic embedding preserves refusals, restoration and concurrent updates',
  {skip:!['rust','all'].includes(process.env.LAWSPEC_NATIVE_LAYOUT_TARGET)&&'requires the Rust acceptance environment'},async()=>{
  const target=await mkdtemp(path.join(tmpdir(),'lawspec-dynamic-embedding-target-'));
  try{for(const machineBits of [32,64])for(const minify of [false,true]){
    const root=await mkdtemp(path.join(tmpdir(),'lawspec-dynamic-embedding-'));
    try{
      const emit=async content=>{
        const result=await generate(content,machineBits,minify);assert.deepEqual(result.diagnostics,[]);
        for(const file of result.files){const dest=path.join(root,file.path);await mkdir(path.dirname(dest),{recursive:true});await writeFile(dest,file.content);}
      };
      await emit(source);
      await writeFile(path.join(root,'Cargo.toml'),templates('rust')['Cargo.toml']);
      await writeFile(path.join(root,'src/lib.rs'),'include!("lawspec_modules.rs");');
      await mkdir(path.join(root,'tests'),{recursive:true});
      await writeFile(path.join(root,'tests/embedding.rs'),`
use lawspec_example::lawspec_abilities::example_dynamicEmbedding::Account;
use lawspec_example::lawspec_data::Refusal;
#[test]
fn public_embedding() {
    let account=std::sync::Arc::new(Account::start());
    assert_eq!(account.try_add(1.5),Ok(1.5));
    let saved=account.state();
    assert_eq!(saved.entries.get("last"),Some(&1.5));
    assert_eq!(account.try_add(-1.0),Err(Refusal::Negative));
    assert_eq!(account.state().balance,1.5);
    assert_eq!(account.try_add(0.5),Ok(2.0));
    account.set_state(saved);
    assert_eq!(account.state().balance,1.5);
    let workers:Vec<_>=(0..4).map(|_|{let account=account.clone(); std::thread::spawn(move||{
        for _ in 0..100 {account.try_add(0.5).unwrap();}
    })}).collect();
    for worker in workers {worker.join().unwrap();}
    assert_eq!(account.state().balance,201.5);
}
`);
      const run=()=>spawnSync('cargo',['test','--offline','--test','embedding'],{cwd:root,encoding:'utf8',maxBuffer:8e6,
        env:{...process.env,CARGO_TARGET_DIR:target}});
      let result=run();assert.equal(result.status,0,result.stdout+result.stderr);
      await emit(source.replace('state.balance + amount','state.balance + amount + 1.0'));
      result=run();assert.ok(Number.isInteger(result.status)&&result.status>0,result.stdout+result.stderr);
      assert.match(result.stdout+result.stderr,/public_embedding.*FAILED|assertion.*failed/s);
    }finally{await rm(root,{recursive:true,force:true});}
  }}finally{await rm(target,{recursive:true,force:true});}
});
