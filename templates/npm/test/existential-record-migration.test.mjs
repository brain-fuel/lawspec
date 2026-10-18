import assert from 'node:assert/strict';
import {test} from 'node:test';
import {mkdtemp,readFile,writeFile,readdir,rm} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {createCompiler} from '../api.mjs';
import {targets} from '../templates.mjs';
import {writeMigration} from '../migration-write.mjs';

const compiler=await createCompiler();
const options={schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]}};
const indexed='type Expr (a :: Type) is | Truth flag :: Bool other :: Int8 where a = Bool | Count number :: Int8 marked :: Bool where a = Int8 end\n';
const concrete=indexed+'definition read (input :: Expr Bool) :: Bool is match input with | Truth flag other -> flag end end';
const generic=indexed+'definition read (input :: Expr a) :: Bool is match input with | Truth flag other -> flag | Count number marked -> marked end end';
const existential='type Shown is Shown held :: a flag :: Bool end\n';
const factories=[existential+'definition create (flag :: Bool) :: Shown is Shown true flag end',
  existential+'definition create (value :: a) :: Shown is Shown value true end\n'+
    'definition active (flag :: Bool) :: Shown is create flag end'];

test('existential record factories format idempotently and generate on every target, width and layout',async()=>{
  const content=await readFile(new URL('../../test/fixtures/canonical-existential-records.lawspec',import.meta.url),'utf8');
  const sources=[{path:'existential.lawspec',content}];
  const formatted=await compiler.format({...options,sources});
  assert.deepEqual(formatted.diagnostics,[]);
  assert.deepEqual((await compiler.format({...options,sources:formatted.formattedSources})).formattedSources,formatted.formattedSources);
  for(const target of targets)for(const machineBits of [32,64])for(const minify of [false,true]){
    const result=await compiler.planGeneration({...options,target,machineBits,minify,sources:formatted.formattedSources});
    assert.deepEqual(result.diagnostics,[],`${target}/${machineBits}/${minify}`);
    assert.ok(result.files.some(file=>file.placement==='source'));
    assert.equal(result.verification.intrinsicDefinitionChecks,true);
  }
});

async function project(body,machineBits){
  const root=await mkdtemp(path.join(os.tmpdir(),'lawspec-existential-migration-'));
  const sources=[{path:'audit.lawspec',content:'unit audit\n'+body}];
  const config={version:1,sources:['audit.lawspec'],machineBits,targets:targets.map(language=>({language,root:language}))};
  const text=JSON.stringify(config,null,2)+'\n';
  await writeFile(path.join(root,'audit.lawspec'),sources[0].content);
  await writeFile(path.join(root,'lawspec.json'),text);
  return {root,sources,text};
}

test('concrete indexed bodies and existential factories authorize validated all-target project writes',async()=>{
  for(const machineBits of [32,64])for(const body of [concrete,...factories]){
    const p=await project(body,machineBits);
    try{
      const report=await writeMigration(compiler,p.root,'lawspec.json',p.text,{sources:p.sources,machineBits});
      assert.equal(report.validated,true,JSON.stringify(report.blockers));
      assert.equal(report.generationPreview.configurationCount,17);
      assert.equal(report.correspondence.sourceTemplates.status,'matched');
      assert.equal(report.validation.nativeConformance,'not-established');
      assert.equal(report.validation.lawVerification,'not-established-by-migration');
      assert.deepEqual(report.filesWritten,['audit.lawspec','lawspec.json']);
      const content=await readFile(path.join(p.root,'audit.lawspec'),'utf8');
      assert.match(content,/of type record\{/);
      const checked=await compiler.check({...options,machineBits,sources:[{path:'audit.lawspec',content}]});
      assert.deepEqual(checked.diagnostics,[]);
    }finally{await rm(p.root,{recursive:true,force:true});}
  }
});

test('matching grouped shapes cannot authorize writes without generic GADT body correspondence',async()=>{
  for(const machineBits of [32,64]){
    const p=await project(generic,machineBits);
    try{
      await assert.rejects(writeMigration(compiler,p.root,'lawspec.json',p.text,{sources:p.sources,machineBits}),error=>{
        assert.equal(error.diagnostics[0].code,'migration-incomplete');
        assert.match(error.message,/source-template correspondence/i);return true;
      });
      assert.equal(await readFile(path.join(p.root,'audit.lawspec'),'utf8'),p.sources[0].content);
      assert.equal(await readFile(path.join(p.root,'lawspec.json'),'utf8'),p.text);
      assert.deepEqual((await readdir(p.root)).sort(),['audit.lawspec','lawspec.json']);
    }finally{await rm(p.root,{recursive:true,force:true});}
  }
});
