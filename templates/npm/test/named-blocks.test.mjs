import assert from 'node:assert/strict';
import {test} from 'node:test';
import {PassThrough} from 'node:stream';
import {createCompiler} from '../api.mjs';
import {serveLanguage} from '../lsp.mjs';
const compiler=await createCompiler();
const options={schemaVersion:5,languageProfile:'1.0-rc.2',verification:{layers:[]}};
const check=content=>compiler.check({...options,sources:[{path:'blocks.lawspec',content}]});

test('the WASM boundary rejects bare, wrong, unknown, missing and extra closers',async()=>{
  for(const [body,expected] of [
    ['unit empty\nend\n','block-close-label-required'],
    ['unit empty\nend\nunit','block-close-label-required'],
    ['unit empty\nend function','block-close-mismatch'],
    ['unit empty\nend spaceship','block-close-unknown'],
    ['unit empty','block-unclosed'],
    ['unit empty\nend unit\nend unit','block-close-unexpected'],
  ]) {
    const result=await check(body);
    assert.deepEqual(result.diagnostics.map(d=>d.code),[expected]);
    assert.ok(result.diagnostics[0].span);
  }
  assert.deepEqual((await check('unit empty\nend\tunit -- closed\n')).diagnostics,[]);
});

test('formatting retains the physical line of harness expressions',async()=>{
  const label='label if flag then "A detailed description of the enabled case, including end unit and end for all." else "Disabled" end if';
  const content=`unit labels
law same is
  definition: for all (flag :: Bool) => flag = flag end for all end definition
end law
harness labels.testing for labels is
  for law same
    ${label}
  end for law
end harness
end unit
`;
  const input={...options,sources:[{path:'labels.lawspec',content}]};
  const formatted=await compiler.format(input);
  assert.deepEqual(formatted.diagnostics,[]);
  assert.ok(formatted.formattedSources[0].content.includes(label));
  assert.deepEqual((await compiler.check({...input,sources:formatted.formattedSources})).diagnostics,[]);
  assert.deepEqual((await compiler.format({...input,sources:formatted.formattedSources})).formattedSources,formatted.formattedSources);
});

const frame=message=>{
  const body=Buffer.from(JSON.stringify(message));
  return Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`),body]);
};
function messages(bytes) {
  const result=[];
  while(bytes.length) {
    const end=bytes.indexOf('\r\n\r\n');
    assert.ok(end>=0);
    const length=Number(/Content-Length: (\d+)/i.exec(bytes.subarray(0,end).toString())[1]);
    result.push(JSON.parse(bytes.subarray(end+4,end+4+length)));
    bytes=bytes.subarray(end+4+length);
  }
  return result;
}

test('LSP diagnostics point to the offending closer and its opener using UTF-16 ranges',async()=>{
  const uri='file:///unlikely-lawspec-block-project/blocks.lawspec';
  const declaration='function "|😀 echo| (value :: Bool) -> Bool is value end unit';
  const text=`-- 😀 documentary text\n\tunit coordinates\n${declaration}\nend unit\n`;
  const input=new PassThrough(),output=new PassThrough(),chunks=[];
  output.on('data',chunk=>chunks.push(chunk));
  const running=serveLanguage(input,output,compiler);
  input.end(Buffer.concat([
    frame({id:1,method:'initialize',params:{rootUri:'file:///unlikely-lawspec-block-project'}}),
    frame({method:'textDocument/didOpen',params:{textDocument:{uri,version:1,text}}}),
    frame({id:2,method:'shutdown'}),
  ]));
  await running;
  const response=messages(Buffer.concat(chunks)).find(r=>r.method==='textDocument/publishDiagnostics');
  const [diagnostic]=response.params.diagnostics;
  assert.equal(diagnostic.code,'block-close-mismatch');
  assert.deepEqual(diagnostic.range,{start:{line:2,character:declaration.indexOf('end unit')},end:{line:2,character:declaration.length}});
  assert.deepEqual(diagnostic.relatedInformation,[{message:'Block opened here.',location:{uri,range:{start:{line:2,character:0},end:{line:2,character:8}}}}]);
});
