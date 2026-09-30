import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp,writeFile,rm} from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {createCompiler} from '../api.mjs';
import {doctor} from '../doctor.mjs';
const compiler=await createCompiler();
const sources=[{path:'rust.lawspec',content:`unit rust_example
successor :: Int8 -> Integer
law \`promotes\` is
 definition is \`for all\` (x :: Int8) . successor x = x + 1 end
 example \`maximum\` is x = 127 expect successor x = 128 end
end`}];

test('Cargo preflight verifies every custom test target and rejects an unsupported toolchain',async t=>{
 const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-rust-doctor-'));
 t.after(()=>rm(root,{recursive:true,force:true}));
 const rustc=path.join(root,'rustc'),cargo=path.join(root,'cargo');
 const command=value=>`#!${process.execPath}\nconsole.log(${JSON.stringify(value)});\n`;
 await writeFile(rustc,command('rustc 1.85.0 (test)'),{mode:0o755});
 await writeFile(path.join(root,'Cargo.toml'),'[package]\nname="example"\nversion="0.1.0"\nedition="2024"\n');
 const dependencies=[['proptest','1.11.0'],['num-bigint','0.4.8'],['num-rational','0.4.2'],['num-complex','0.4.6'],['num-traits','0.2.19']];
 const pkg={id:'example',manifest_path:path.join(root,'Cargo.toml'),edition:'2024',targets:[{kind:['lib'],src_path:path.join(root,'library/lib.rs')},{kind:['test'],test:true,src_path:path.join(root,'checks/one_lawspec.rs')}]};
 const metadata={packages:[pkg,...dependencies.map(([name,version])=>({id:name,name,version}))],resolve:{nodes:[{id:'example',deps:dependencies.map(([name])=>({name:name.replaceAll('-','_'),pkg:name}))}]}};
 const target={language:'rust',sourceDir:'library',testDir:'checks',rustc,cargo};
 const artifacts=['one','two'].map(n=>({path:`checks/${n}_lawspec.rs`,placement:'test'}));
 const save=()=>writeFile(cargo,command(JSON.stringify(metadata)),{mode:0o755});
 await save();
 const missing=await doctor(target,root,artifacts);
 assert.equal(missing.ok,false);assert.match(missing.message,/every generated Rust test/);
 pkg.targets.push({kind:['test'],test:true,src_path:path.join(root,'checks/two_lawspec.rs')});
 await save();assert.equal((await doctor(target,root,artifacts)).ok,true);
 await writeFile(rustc,command('rustc 1.84.1 (test)'));
 assert.equal((await doctor(target,root,artifacts)).ok,false);
 await writeFile(rustc,command('rustc 1.85.0 (test)'));
 pkg.edition='2021';await save();
 assert.equal((await doctor(target,root,artifacts)).ok,false);
});
