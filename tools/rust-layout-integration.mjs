// Compile a real custom Cargo layout, then verify adapter and manifest ownership.
import {execFileSync} from 'node:child_process';
import {mkdir,readFile,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import {createCompiler} from '../npm/api.mjs';
import {templates} from '../npm/templates.mjs';
import {doctor} from '../npm/doctor.mjs';
import {planWrites,applyWrites} from '../npm/files.mjs';
const root=path.resolve(import.meta.dirname,'../.artifacts/rust-custom-layout');
await rm(root,{recursive:true,force:true});await mkdir(root,{recursive:true});
const sourceDir='library/native',testDir='checks/properties';
const sources=['one','two'].map(n=>({path:`${n}.lawspec`,content:`unit layout.${n}
successor :: Int8 -> Integer
law \`promotes\` is definition is \`for all\` (x :: Int8) . successor x = x + 1 end
example \`maximum\` is x = 127 expect successor x = 128 end end`}));
const compiler=await createCompiler();
const result=await compiler.planGeneration({sources,target:'rust',sourceDir,testDir});
assert.deepEqual(result.diagnostics,[]);
const scaffold=templates('rust');
const tests=result.files.filter(f=>f.placement==='test'&&f.path.endsWith('_lawspec.rs'));
const manifest=scaffold['Cargo.toml']+`\n[lib]\npath="${sourceDir}/lib.rs"\n`+tests.map((f,i)=>`\n[[test]]\nname="laws_${i}"\npath="${f.path}"\n`).join('');
await writeFile(path.join(root,'Cargo.toml'),manifest);
await mkdir(path.join(root,sourceDir),{recursive:true});
await writeFile(path.join(root,sourceDir,'lib.rs'),scaffold['src/lib.rs']);
const target={language:'rust',sourceDir,testDir};
const report=await doctor(target,root,result.files);
assert.equal(report.ok,true,report.message);
await applyWrites([await planWrites(root,result.files)]);
const implementation='use crate::lawspec_runtime::Integer;\npub fn successor(value:i8)->Integer {(i16::from(value)+1).into()}\n';
for(const f of result.files.filter(f=>f.ownership==='user'))await writeFile(path.join(root,f.path),implementation);
execFileSync('cargo',['test',...(process.env.LAWSPEC_RUST_RELEASE==='1'?['--release']:[])],{cwd:root,stdio:'inherit'});
const plan=await planWrites(root,result.files);
assert.equal(plan.changes.length,0);
for(const f of result.files.filter(f=>f.ownership==='user'))assert.equal(await readFile(path.join(root,f.path),'utf8'),implementation);
assert.equal(await readFile(path.join(root,'Cargo.toml'),'utf8'),manifest);
const generated=tests[0];await writeFile(path.join(root,generated.path),'// user edit\n');
await assert.rejects(planWrites(root,result.files));
assert.equal(await readFile(path.join(root,generated.path),'utf8'),'// user edit\n');
console.log('Rust custom source/test roots compile; regeneration preserves adapters/build files and protects edited tests.');
