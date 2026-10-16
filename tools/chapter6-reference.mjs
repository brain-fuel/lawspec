// Generated from templates/tools/chapter6-reference.mjs by lawspec-dev generate. Do not edit.
// Rebuild independent instruction vectors from the course's pinned decoder.
import assert from 'node:assert/strict';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
import {existsSync} from 'node:fs';
import {mkdir,mkdtemp,readFile,writeFile} from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

const root=path.resolve(import.meta.dirname,'..');
const revision='52611ad9bc2a30d329293b0cf58be672d672ac96';
const sources=[
  ['simulator/src/cpu/alu.ts','0086d734988de6410fb8c5e9ea6cec0e6b68d804d992580ead139baf476d3934'],
  ['simulator/src/util/asm.ts','023e23fb145d7d3845e093185863a39b095024ababffd1ba56f79c055629aefa'],
];
const digest=text=>createHash('sha256').update(text).digest('hex');
const base=path.join(root,'.artifacts/chapter6-reference');
await mkdir(base,{recursive:true});
const directory=await mkdtemp(path.join(base,'run-'));
await writeFile(path.join(directory,'package.json'),JSON.stringify({type:'module'}));
for(const [file,hash] of sources) {
  const url=`https://raw.githubusercontent.com/nand2tetris/web-ide/${revision}/${file}`;
  const response=await fetch(url);
  assert.ok(response.ok,`${response.status} ${url}`);
  const source=await response.text();
  assert.equal(digest(source),hash,`Upstream bytes changed: ${file}`);
  const output=path.join(directory,file);
  await mkdir(path.dirname(output),{recursive:true});
  await writeFile(output,source);
}
const license=await fetch(`https://raw.githubusercontent.com/nand2tetris/web-ide/${revision}/LICENSE`);
assert.ok(license.ok);
await writeFile(path.join(directory,'LICENSE'),await license.text());
const local=path.join(root,'.integration/typescript/node_modules/.bin/tsc');
const tsc=process.env.LAWSPEC_TSC??(existsSync(local)?local:'tsc');
const compiled=spawnSync(tsc,['--target','ES2022','--module','NodeNext','--moduleResolution','NodeNext',
  '--rootDir',directory,'--outDir',path.join(directory,'build'),...sources.map(([file])=>path.join(directory,file))],{encoding:'utf8'});
assert.equal(compiled.error,undefined,String(compiled.error));
assert.equal(compiled.status,0,compiled.stdout+compiled.stderr);
const {asm}=await import(pathToFileURL(path.join(directory,'build/simulator/src/util/asm.js')));
const instructions=new Map();
for(let value=0xE000;value<=0xFFFF;value++) {
  const source=asm(value);
  if(source==='#ERR'||instructions.has(source)) continue;
  instructions.set(source,value.toString(2).padStart(16,'0'));
}
assert.equal(instructions.size,1792,'28 computations × 8 destinations × 8 jumps');
const aDigest=createHash('sha256');
for(let value=0;value<32768;value++) {
  assert.equal(asm(value),'@'+value);
  aDigest.update(asm(value)+'\t'+value.toString(2).padStart(16,'0')+'\n');
}
const vectors=[...instructions].map(([source,word])=>source+'\t'+word+'\n').join('');
const provenance={version:1,repository:'https://github.com/nand2tetris/web-ide',revision,
  decoder:'simulator/src/util/asm.ts',sources:sources.map(([path,sha256])=>({path,sha256})),
  license:`https://github.com/nand2tetris/web-ide/blob/${revision}/LICENSE`,
  aInstructions:{count:32768,sha256:aDigest.digest('hex'),encoding:'source TAB sixteen binary digits LF, addresses in ascending order'},
  cInstructions:{count:1792,sha256:digest(vectors),file:'c-instructions.tsv',encoding:'source TAB sixteen binary digits LF, first canonical decoder output in numeric word order'}};
const fixture=path.join(root,'test/fixtures/chapter6');
const outputs=[['c-instructions.tsv',vectors],['provenance.json',JSON.stringify(provenance,null,2)+'\n']];
const args=process.argv.slice(2);
assert.ok(args.length===0||(args.length===1&&args[0]==='--check'),'Use --check or no arguments');
if(args[0]==='--check') for(const [file,content] of outputs)
  assert.equal(await readFile(path.join(fixture,file),'utf8'),content,file);
else {
  await mkdir(fixture,{recursive:true});
  for(const [file,content] of outputs) await writeFile(path.join(fixture,file),content);
}
console.log(JSON.stringify({aInstructions:32768,cInstructions:1792,revision,checked:args[0]==='--check'}));
