import assert from 'node:assert/strict';
import {test} from 'node:test';
import {PassThrough} from 'node:stream';
import {mkdtemp,writeFile,rm,mkdir,symlink} from 'node:fs/promises';
import {existsSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {spawnSync} from 'node:child_process';
import {createCompiler} from '../api.mjs';
import {serveLanguage,utf16Position} from '../lsp.mjs';

const text=`unit matchWarnings

function selected (value :: Bool) -> Integer is
  first matching case of value:
    when #any then 1
    when false then 2
    otherwise 3
  end case
end function
law retained is definition: selected true must be 1 end definition end law

end unit
`;
const input={languageProfile:'1.0-rc.2',verification:{layers:[]},sources:[{path:'warnings.lawspec',content:text}]};
const strip=({warnings,warningAnalysis,...value})=>value;

test('opt-in match warnings preserve API results, evidence, and every target artifact',async()=>{
  const compiler=await createCompiler();
  const {targets}=await import('../templates.mjs');
  for(const machineBits of [32,64]){
    const request={...input,machineBits};
    const before=await compiler.check(request), after=await compiler.check({...request,warnMatches:true});
    assert.deepEqual(after.diagnostics,[]);
    assert.deepEqual(after.warnings.map(w=>w.code),['case-unreachable','case-unnecessary-fallback']);
    assert.ok(after.warnings.every(w=>w.severity==='warning'&&w.at.file==='warnings.lawspec'&&(w.span.end.line>w.span.start.line||w.span.end.column>w.span.start.column)));
    assert.equal(after.warningAnalysis.complete,false);
    assert.deepEqual(strip(after),before);
    assert.deepEqual(await compiler.check({...request,warnMatches:false}),before);
    assert.ok(after.evidence.filter(e=>e.stage==='law').every(e=>e.status==='not-verified'));
    assert.equal(after.verification.selection,'no-selected-checks');
    for(const target of targets){
      const normal=await compiler.planGeneration({...request,target});
      const warned=await compiler.planGeneration({...request,target,warnMatches:true});
      assert.deepEqual(warned.diagnostics,[],target);
      assert.deepEqual(strip(warned),normal,target);
    }
    for(const body of [
      'first matching case of value: when true then 1 end case',
      'first matching case of value: when #any then 1 when false then missing end case'
    ]){
      const bad={...request,sources:[{path:'bad.lawspec',content:`unit bad

function selected (value :: Bool) -> Integer is ${body} end function

end unit
`}]};
      const normal=await compiler.check(bad),warned=await compiler.check({...bad,warnMatches:true});
      assert.ok(warned.diagnostics.length);assert.deepEqual(warned,normal);
    }
  }
});

test('CLI match warnings do not fail checking or pollute JSON, while intrinsic errors still fail',async()=>{
  const root=await mkdtemp(path.join(tmpdir(),'lawspec-match-warnings-'));
  try{
    await writeFile(path.join(root,'lawspec.json'),JSON.stringify({version:2,languageProfile:'1.0-rc.2',verification:{layers:[]},sources:['source.lawspec'],targets:[],cache:false}));
    await writeFile(path.join(root,'source.lawspec'),text);
    const cli=fileURLToPath(new URL('../bin/lawspec.mjs',import.meta.url));
    const invoke=(...args)=>spawnSync(process.execPath,[cli,'check',...args],{cwd:root,encoding:'utf8',timeout:120000});
    const normal=invoke();assert.equal(normal.status,0,normal.stderr);assert.doesNotMatch(normal.stderr,/case-unreachable|case-unnecessary-fallback/);
    const warned=invoke('--warn-matches');assert.equal(warned.status,0,warned.stderr);
    assert.match(warned.stderr,/warning case-unreachable/);assert.match(warned.stderr,/warning case-unnecessary-fallback/);
    assert.match(warned.stdout,/No law checks selected/);
    const json=invoke('--warn-matches','--json');assert.equal(json.status,0,json.stderr);assert.doesNotMatch(json.stderr,/case-unreachable|case-unnecessary-fallback/);
    assert.equal(JSON.parse(json.stdout).warnings.length,2);
    await writeFile(path.join(root,'source.lawspec'),text.replace('when #any then 1','when true then 1').replace('when false then 2','when true then 2').replace('    otherwise 3\n',''));
    const bad=invoke('--warn-matches','--json');assert.equal(bad.status,1,bad.stderr);
    assert.ok(JSON.parse(bad.stdout).diagnostics.length);
  }finally{await rm(root,{recursive:true,force:true});}
});

function frame(message){const body=Buffer.from(JSON.stringify({jsonrpc:'2.0',...message}));return Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`),body]);}
function messages(buffer){const result=[];while(buffer.length){const h=buffer.indexOf('\r\n\r\n');const size=Number(/Content-Length:\s*(\d+)/i.exec(buffer.subarray(0,h).toString())[1]);result.push(JSON.parse(buffer.subarray(h+4,h+4+size)));buffer=buffer.subarray(h+4+size);}return result;}
async function protocol(compiler,initializationOptions,content){
  const source='file:///unlikely-lawspec-warning-project/warnings.lawspec';
  const stream=new PassThrough(), output=new PassThrough(), chunks=[];
  output.on('data',data=>chunks.push(data));
  const running=serveLanguage(stream,output,compiler);
  stream.end(Buffer.concat([
    frame({id:1,method:'initialize',params:{rootUri:'file:///unlikely-lawspec-warning-project',initializationOptions}}),
    frame({method:'textDocument/didOpen',params:{textDocument:{uri:source,version:1,text:content}}}),
    frame({method:'workspace/didChangeConfiguration',params:{settings:{lawspec:{warnMatches:true}}}}),
    frame({method:'workspace/didChangeConfiguration',params:{settings:{lawspec:{warnMatches:false}}}}),
    frame({id:2,method:'shutdown'})
  ]));
  await running;return messages(Buffer.concat(chunks));
}

test('LSP delivers actual compiler warnings with UTF-16 ranges and clears them when disabled',async()=>{
  const compiler=await createCompiler();
  const content=`unit unicodeWarnings

function selected (value :: Bool) -> Text is
  first matching case of value: when #any then "😀" when false then "second" otherwise "third" end case
end function

end unit
`;
  const responses=await protocol(compiler,{warnMatches:false},content);
  const published=responses.filter(r=>r.method==='textDocument/publishDiagnostics').map(r=>r.params.diagnostics);
  assert.deepEqual(published[0],[]);assert.deepEqual(published[2],[]);
  assert.deepEqual(published[1].map(d=>[d.code,d.severity]),[['case-unreachable',2],['case-unnecessary-fallback',2]]);
  const lineIndex=content.split('\n').findIndex(line=>line.includes('when false'));
  const line=content.split('\n')[lineIndex];
  assert.deepEqual(published[1][0].range.start,{line:lineIndex,character:line.indexOf('when false')});
  assert.ok(published[1][0].range.end.character>published[1][0].range.start.character);
  assert.deepEqual(utf16Position('😀\twhen',{line:1,column:9}),{line:0,character:3});
  const enabled=await protocol(compiler,{warnMatches:true},content);
  assert.equal(enabled.find(r=>r.method==='textDocument/publishDiagnostics').params.diagnostics.length,2);
  const invalid=await protocol(compiler,{warnMatches:true},content.replace('"second"','missing'));
  const errors=invalid.find(r=>r.method==='textDocument/publishDiagnostics').params.diagnostics;
  assert.ok(errors.length);assert.ok(errors.every(d=>d.severity===1));
});

const localTsc=fileURLToPath(new URL('../../.integration/typescript/node_modules/.bin/tsc',import.meta.url));
const tsc=process.env.LAWSPEC_TSC??(existsSync(localTsc)?localTsc:null);
test('published warning declarations enforce Boolean selection and incomplete analysis',
  {skip:tsc?false:'set LAWSPEC_TSC for the published declaration consumer'},async()=>{
  const directory=await mkdtemp(path.join(tmpdir(),'lawspec-warning-types-'));
  try{
    await writeFile(path.join(directory,'package.json'),'{"type":"module"}');
    await mkdir(path.join(directory,'node_modules'));
    await symlink(fileURLToPath(new URL('..',import.meta.url)),path.join(directory,'node_modules','lawspec'),'dir');
    await writeFile(path.join(directory,'consumer.ts'),`import {createCompiler, type CheckRequest, type MatchWarning, type MatchWarningAnalysis} from 'lawspec';
const request:CheckRequest={languageProfile:'1.0-rc.2',verification:{layers:[]},warnMatches:true,sources:[]};
const result=await (await createCompiler()).check(request);
for(const warning of result.warnings??[]){
 const severity:'warning'=warning.severity;
 const location:number=warning.span.start.column;
 const checked:MatchWarning=warning;
 console.log(severity,location,checked.code);
}
if(result.warningAnalysis){
 const complete:false=result.warningAnalysis.complete;
 const kind:'match-reachability'=result.warningAnalysis.kind;
 const analysis:MatchWarningAnalysis=result.warningAnalysis;
 console.log(complete,kind,analysis.scope);
}
// @ts-expect-error warning selection must be Boolean
const invalid:CheckRequest={languageProfile:'1.0-rc.2',sources:[],warnMatches:'yes'};
// @ts-expect-error authoring warning analysis cannot certify completeness
const complete:MatchWarningAnalysis={kind:'match-reachability',complete:true,scope:'ordered-pattern-specialization',reason:''};
`);
    const result=spawnSync(tsc,['--noEmit','--strict','--target','ES2022','--module','NodeNext',
      '--moduleResolution','NodeNext','consumer.ts'],{cwd:directory,encoding:'utf8'});
    assert.equal(result.status,0,result.stdout+result.stderr);
  }finally{await rm(directory,{recursive:true,force:true});}
});
