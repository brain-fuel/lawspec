// Generated from templates/npm/test/authoring.test.mjs by lawspec-dev generate. Do not edit.
import {semanticFacts} from './compiler-input.mjs';
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { PassThrough } from 'node:stream';
import { serveLanguage, utf16Position } from '../lsp.mjs';
import { explainLaw } from '../explain.mjs';

test('documentary prelude function aliases retain declaration identities and ordinary scope priority',async()=>{
  const {createCompiler}=await import('../api.mjs');
  const compiler=await createCompiler();
  const sources=[{path:'domain.lawspec',content:`unit domain

function caseFold (value :: Text) -> Text is value end function

end unit
`},
    {path:'consumer.lawspec',content:`unit consumer
import domain (caseFold)
function setOf (value :: Bool) -> Bool is value end function
law linked is
  definition: true end definition
  references:
    ref function prelude.caseFold
    ref function caseFold
    ref function prelude.setOf
    ref function setOf
    ref function prelude.milliseconds
    ref function prelude.sameItems
  end references
end law
end unit
`}];
  for(const machineBits of [32,64]){
    const input={schemaVersion:5,languageProfile:'1.0-rc.2',machineBits,verification:{layers:[]},sources};
    const result=await compiler.check(input);assert.deepEqual(result.diagnostics,[]);
    const law=result.laws.find(law=>law.owner==='consumer');assert.ok(law);
    assert.deepEqual(law.references.map(ref=>[ref.target.unit,ref.target.name]),[
      ['lawspec.text','textCaseFold'],['domain','caseFold'],['lawspec.collections','eqSetOf'],
      ['consumer','setOf'],['lawspec.time','milliseconds'],['lawspec.matchers','matchersSameItems']]);
    assert.ok(result.evidence.filter(item=>item.stage==='law').every(item=>item.status==='not-verified'));
    for(const reference of ['ref function prelude.notAFunction','ref law prelude.caseFold']){
      const bad=await compiler.check({...input,sources:[{path:'bad.lawspec',content:
        `unit bad\nlaw linked is definition: true end definition references: ${reference} end references end law\nend unit`}]});
      assert.ok(bad.diagnostics.some(item=>item.code==='reference'));
    }
  }
});

test('formatting uses parser roles for record-type separators across imported types without altering value or pattern commas',async()=>{
  const {readFile}=await import('node:fs/promises');
  const {createCompiler}=await import('../api.mjs');
  const {targets}=await import('../templates.mjs');
  const compiler=await createCompiler();
  const content=await readFile(new URL('../../test/fixtures/canonical-record-type-separators.lawspec',import.meta.url),'utf8');
  const companion=`unit formatter.consumer
import formatter.recordSeparators as picture (Picture, sample, display)
function reference (value :: picture.Picture) -> record{original :: picture.Picture,note :: Text} is
record{original = value, note = "keep,this"}
end function

end unit
`;
  for(const machineBits of [32,64]){
    const input={schemaVersion:5,languageProfile:'1.0-rc.2',machineBits,verification:{layers:['exhaustive','examples']},
      sources:[{path:'pictures.lawspec',content},{path:'consumer.lawspec',content:companion}]};
    const before=await compiler.check({...input});assert.deepEqual(before.diagnostics,[]);
    const formatted=await compiler.format(input);assert.deepEqual(formatted.diagnostics,[]);
    const output=formatted.formattedSources[0].content;
    const compact=output.replace(/\s+/g,' ');
    assert.ok(output.includes('  width of type Nat -- Keep the comment\'s comma, λ and 😀.'));
    assert.ok(output.includes('    height :: Nat\n    caption :: Text\n  }\n  pair :: (Bool, Text)\n}'));
    assert.ok(compact.includes('record{height = 2, caption = "a,b"}'));
    assert.ok(compact.includes('record{caption = name, height = _}'));
    const companionOutput=formatted.formattedSources[1].content.replace(/\s+/g,' ');
    assert.ok(companionOutput.includes('record{original :: picture.Picture note :: Text}'));
    assert.ok(companionOutput.includes('record{original = value, note = "keep,this"}'));
    const after=await compiler.check({...input,sources:formatted.formattedSources});
    assert.deepEqual(after.diagnostics,[]);assert.deepEqual(semanticFacts(after),semanticFacts(before));
    const repeated=await compiler.format({...input,sources:formatted.formattedSources});
    assert.deepEqual(repeated.diagnostics,[]);assert.deepEqual(repeated.formattedSources,formatted.formattedSources);
    for(const target of targets)for(const minify of [false,true]){
      const generated=await compiler.planGeneration({...input,target,minify,sources:formatted.formattedSources});
      assert.deepEqual(generated.diagnostics,[],target);assert.ok(generated.files.length,target);
    }
  }
});

test('formatting preserves multiline literal contents and processes trailing block endings',async()=>{
  const {createCompiler}=await import('../api.mjs');
  const compiler=await createCompiler();
  const content=`unit literal.boundaries

function text (ignored :: ()) -> Text is "first
${'   '}
second" end function
function same (value :: Bool) -> Bool is
value
end function

end unit
`;
  const expected=content.replace('\nvalue\n','\n  value\n');
  for(const machineBits of [32,64]){
    const input={schemaVersion:5,languageProfile:'1.0-rc.2',machineBits,
      verification:{layers:[]},sources:[{path:'literal.lawspec',content}]};
    const before=await compiler.check({...input});
    assert.deepEqual(before.diagnostics,[]);
    const formatted=await compiler.format(input);
    assert.deepEqual(formatted.diagnostics,[]);
    assert.equal(formatted.formattedSources[0].content,expected);
    const after=await compiler.check({...input,sources:formatted.formattedSources});
    assert.deepEqual(after.diagnostics,[]);
    assert.deepEqual(semanticFacts(after),semanticFacts(before));
    const repeated=await compiler.format({...input,sources:formatted.formattedSources});
    assert.deepEqual(repeated.diagnostics,[]);
    assert.deepEqual(repeated.formattedSources,formatted.formattedSources);
  }
});

test('formatting retains long scenario arguments and typed behavior through nested delivery and recovery',async()=>{
  const {readFile}=await import('node:fs/promises');
  const {createCompiler}=await import('../api.mjs');
  const {targets}=await import('../templates.mjs');
  const compiler=await createCompiler();
  const file='canonical-scenario-format-boundaries.lawspec';
  const content=await readFile(new URL('../../test/fixtures/'+file,import.meta.url),'utf8');
  const commandLines=source=>source.split('\n').map(line=>line.trimStart())
    .filter(line=>/^(notice "|reply <- echo |expect reply = |send receipt )/.test(line));
  for(const machineBits of [32,64]){
    const input={schemaVersion:5,languageProfile:'1.0-rc.2',machineBits,verification:{layers:[]},sources:[{path:file,content}]};
    const before=await compiler.check({...input});assert.deepEqual(before.diagnostics,[]);
    const formatted=await compiler.format(input);assert.deepEqual(formatted.diagnostics,[]);
    const output=formatted.formattedSources[0].content;
    assert.ok(commandLines(content).length);assert.deepEqual(commandLines(output),commandLines(content));
    const after=await compiler.check({...input,sources:formatted.formattedSources});
    assert.deepEqual(after.diagnostics,[]);assert.deepEqual(semanticFacts(after),semanticFacts(before));
    const repeated=await compiler.format({...input,sources:formatted.formattedSources});
    assert.deepEqual(repeated.diagnostics,[]);assert.deepEqual(repeated.formattedSources,formatted.formattedSources);
    for(const minify of [false,true])for(const target of targets){
      const request={...input,target,minify};
      const original=await compiler.planGeneration(request);
      const rewritten=await compiler.planGeneration({...request,sources:formatted.formattedSources});
      assert.deepEqual(original.diagnostics,[],target);assert.deepEqual(rewritten.diagnostics,[],target);
      assert.deepEqual(rewritten.files.map(file=>file.path),original.files.map(file=>file.path),target);
      for(let index=0;index<original.files.length;index++){
        const before=original.files[index],after=rewritten.files[index];
        // Existing remote identities include source provenance in their
        // dependency hashes. Retain every other byte, including definitions,
        // dispatch names and descriptors, while accounting for that rekeying.
        const remote=/(?:^|\/)(?:LawSpecRemote\.(?:java|hs)|lawspec_remote\.(?:py|mjs|ts|go|rs|erl)|RemoteDefinitions\.fs|LawSpecRemoteDefinitions\.swift)$/.test(before.path);
        const identities=file=>remote?{...file,content:file.content.replace(/sha3-256:[0-9a-f]{64}/g,'<remote dependency hash>')}:file;
        assert.deepEqual(identities(after),identities(before),target+': '+before.path);
      }
      assert.deepEqual(rewritten.tests,[]);assert.deepEqual(original.tests,[]);
    }
  }
});

test('formatting preserves checked snapshots across resource, harness, workflow and scenario blocks',async()=>{
  const {readFile}=await import('node:fs/promises');
  const {createCompiler}=await import('../api.mjs');
  const compiler=await createCompiler();
  const fixtures=[
    ['canonical-formatter-resources-harness.lawspec',[
      'resource Scratch is\n  acquire is\n    openScratch ()\n  end',
      '  for law same\n    use flags for value\n    repeat 2\n  end for law\n  benchmark',
      '  benchmark `if all end is only a benchmark name` is\n    true\n  end',
    ]],
    ['canonical-formatter-model-workflow.lawspec',[
      'model store :: shared Store by Bool is\n  start openStore by false',
      '  all\n    first :: Bool -> Bool\n    second :: Bool -> Bool\n  end all\n  combine chooseFirst',
    ]],
    ['canonical-model-layer-selection.lawspec',[
      'supervisor bank is\n  one for one\n  at most 3 restarts in 5s\n  permanent account\nend',
      '  with\n    receive receipt m or else\n      balance\n    end or else\n    expect m = 5\n  end par',
    ]],
  ];
  for(const [file,fragments] of fixtures){
    const original=await readFile(new URL('../../test/fixtures/'+file,import.meta.url),'utf8');
    const content=original.split('\n').map(line=>line.trimStart()).join('\n');
    for(const machineBits of [32,64]){
      const input={schemaVersion:5,languageProfile:'1.0-rc.2',machineBits,
        verification:{layers:[]},sources:[{path:file,content}]};
      const before=await compiler.check({...input});
      assert.deepEqual(before.diagnostics,[],file);
      const formatted=await compiler.format(input);
      assert.deepEqual(formatted.diagnostics,[],file);
      const output=formatted.formattedSources[0].content;
      for(const fragment of fragments)assert.ok(output.includes(fragment),file+': '+fragment);
      const after=await compiler.check({...input,sources:formatted.formattedSources});
      assert.deepEqual(after.diagnostics,[],file);
      assert.deepEqual(semanticFacts(after),semanticFacts(before),file);
      const repeated=await compiler.format({...input,sources:formatted.formattedSources});
      assert.deepEqual(repeated.diagnostics,[]);
      assert.deepEqual(repeated.formattedSources,formatted.formattedSources,file);
    }
  }
});

test('canonical stateful procedures preserve state, sequencing and equality precedence through the SDK',async()=>{
  const {createCompiler}=await import('../api.mjs');
  const compiler=await createCompiler();
  const content=`unit remembered

ability Signal is signal of type Bool -> Bool end ability
handler remembering for Signal with state previous :: Bool start let initial = false in initial end let  is
  operation signal value is ~previous := not previous and value; previous end operation
end handler
procedure twice (value :: Bool) -> Bool uses Signal is signal value; signal value end procedure
function selected (left :: Bool) (right :: Bool) -> Bool is not left = false && right = false end function
law twice using remembering is definition: for all (value :: Bool) => twice value must be false end for all end definition
expect twice value = expected in table (value,expected): row false,false row true,false end table end law
law selected is definition: for all (left :: Bool) (right :: Bool) => selected left right must be (left and not right) end for all end definition end law

end unit
`;
  const options={schemaVersion:5,languageProfile:'1.0-rc.2'};
  for(const machineBits of [32,64]) {
    const input={...options,machineBits,sources:[{path:'remembered.lawspec',content}]};
    const unchecked=await compiler.check({...input,verification:{layers:[]}});
    assert.deepEqual(unchecked.diagnostics,[]);
    assert.equal(unchecked.verification.selection,'no-selected-checks');
    assert.equal(unchecked.evidence.filter(item=>item.stage==='law').length,2);
    assert.ok(unchecked.evidence.filter(item=>item.stage==='law').every(item=>item.status==='not-verified'));
    const checked=await compiler.check({...input,verification:{layers:['exhaustive','examples']}});
    assert.deepEqual(checked.diagnostics,[]);
    assert.equal(checked.evidence.filter(item=>item.stage==='law').length,2);
    assert.ok(checked.evidence.filter(item=>item.stage==='law').every(item=>item.status==='exhaustively-checked'));
    for(const mutant of [content.replace('initial = false','initial = true'),
      content.replace('not previous and value','previous or value'),
      content.replace('signal value; signal value','signal value'),
      content.replace('&& right = false','|| right = false')]) {
      const result=await compiler.check({...input,sources:[{path:'remembered.lawspec',content:mutant}],verification:{layers:['exhaustive']}});
      assert.ok(result.diagnostics.some(item=>item.code==='refuted'),JSON.stringify(result.diagnostics));
    }
    const formatted=await compiler.format({...input,verification:{layers:[]}});
    assert.deepEqual(formatted.diagnostics,[]);
    const repeated=await compiler.format({...input,sources:formatted.formattedSources,verification:{layers:[]}});
    assert.deepEqual(repeated.diagnostics,[]);
    assert.deepEqual(repeated.formattedSources,formatted.formattedSources);
  }
});

const law = { id: 'shop::law::identity', inputs: [{ name: 'amount', type: { kind: 'constructor', name: 'Integer', arguments: [] }, predicates: [] }],
  assertion: { kind: 'equal', left: { text: 'refund amount' }, right: { text: 'Approved' } },
  location: { file: 'shop.lawspec', line: 1, column: 1 }, trace: [], examples: [], description: 'A captured amount may be refunded.', rationale: '' };

test('explanation views retain the same authoritative typed assertion and evidence', () => {
  const result = { evidence: [{ declaration: law.id, status: 'not-verified', reason: 'No law verification layers selected.' }] };
  for (const view of ['developer', 'business', 'formal', 'evidence']) {
    const explanation = explainLaw(law, result, view);
    assert.equal(explanation.assertion, law.assertion);
    assert.deepEqual(explanation.evidence, result.evidence);
  }
  assert.match(explainLaw(law, result, 'business').text, /must be Approved/);
  assert.match(explainLaw(law, result, 'evidence').text, /NOT-VERIFIED/);
  const wholeLaw = { ...law, inputs: [{ ...law.inputs[0], type: { kind: 'constructor', name: 'BigUInt', arguments: [] } }] };
  assert.match(explainLaw(wholeLaw, result, 'business').text, /amount of type Whole/);
  assert.throws(() => explainLaw(law, result, 'other'), /Choose --view/);
});

test('explanation views preserve nested existential scope and negation', () => {
  const assertion = { kind: 'not', body: { kind: 'exists',
    binder: { id: 'witness', name: 'authorization', type: { kind: 'constructor', name: 'Bool', arguments: [] } },
    predicates: [{ text: 'authorization = active' }], body: law.assertion } };
  const scoped = { ...law, assertion };
  assert.equal(explainLaw(scoped, {}, 'business').assertion, assertion);
  assert.match(explainLaw(scoped, {}, 'business').text, /There must not exist authorization of type Bool where authorization = active/);
  assert.match(explainLaw(scoped, {}, 'formal').text, /not \(there exists \(authorization of type Bool where authorization = active\) such that/);
});

test('documentary metadata remains separate from proposition identity and evidence', () => {
  const metadata = { id: 'REVIEW-001', owner: 'Payments.Review' };
  const documented = { ...law, metadata };
  const result = { evidence: [{ declaration: law.id, status: 'not-verified', reason: 'No law checks selected.' }] };
  for (const view of ['developer', 'business', 'formal', 'evidence']) {
    const explanation = explainLaw(documented, result, view);
    assert.equal(explanation.metadata, metadata);
    assert.equal(explanation.law, law.id);
    assert.equal(explanation.assertion, law.assertion);
    assert.deepEqual(explanation.evidence, result.evidence);
  }
  assert.match(explainLaw(documented, result, 'business').text, /Requirement: REVIEW-001\nOwner: Payments.Review/);
  assert.equal(explainLaw(documented, result, 'formal').text, explainLaw(law, result, 'formal').text);
});

test('documentary links remain finite in all explanation views without changing evidence', () => {
  const references = [
    { kind: 'law', target: { id: law.id, unit: 'shop', name: 'identity' }, selector: { kind: 'named-reference', name: '\"|policy|' } },
    { kind: 'function', target: { id: 'shop::refund', unit: 'shop', name: 'refund' } },
    { kind: 'external', name: '\"|policy|', resource: 'approved wording' },
  ];
  const documented = { ...law, references };
  const result = { evidence: [{ declaration: law.id, status: 'incomplete', reason: 'A bounded miss is inconclusive.' }] };
  for (const view of ['developer', 'business', 'formal', 'evidence']) {
    const explanation = explainLaw(documented, result, view);
    assert.equal(explanation.references, references);
    assert.equal(explanation.assertion, law.assertion);
    assert.deepEqual(explanation.evidence, result.evidence);
  }
  assert.match(explainLaw(documented, result, 'business').text, /Reference: ref law shop.identity references\.\"\|policy\|/);
  assert.match(explainLaw(documented, result, 'developer').text, /Reference: ref function shop.refund/);
  for (const view of ['formal', 'evidence']) assert.equal(explainLaw(documented, result, view).text, explainLaw(law, result, view).text);
  assert.match(explainLaw({ ...law, references: ['legacy citation'] }, result, 'business').text, /Reference: legacy citation/);
  const prelude = { ...law, references: [{ kind: 'law', target: { id: 'prelude::law::left inverse', unit: 'prelude', name: 'left inverse' } }] };
  assert.match(explainLaw(prelude, result, 'business').text, /ref law prelude\."\|left inverse\|/);
});

test('configured witness strategies stay separate from propositions and completed evidence', () => {
  const witnesses = [{ binder: 'shop::law::identity::logical::0', path: ['amount', 'answer'], expression: { text: 'amount + 1' } }];
  const configured = { ...law, harness: { witnesses } };
  const result = { evidence: [{ declaration: law.id, status: 'not-verified', reason: 'No law layers selected.' }] };
  for (const view of ['developer', 'business', 'formal', 'evidence']) {
    const explanation = explainLaw(configured, result, view);
    assert.equal(explanation.witnesses, witnesses);
    assert.equal(explanation.assertion, law.assertion);
    assert.deepEqual(explanation.evidence, result.evidence);
    if (['business', 'formal'].includes(view)) assert.equal(explanation.text, explainLaw(law, result, view).text);
    else assert.match(explanation.text, /Configured witness \(not completed evidence\): definition.amount.answer = amount \+ 1/);
  }
});

test('configured scoped searches retain the same obligation and evidence in every view', () => {
  const searches = [{binder: 'shop::law::identity::logical::0', path: ['amount', 'answer'], strategy: 'answers'}];
  const configured = {...law, harness: {searches}};
  const result = {evidence: [{declaration: law.id, status: 'incomplete', reason: 'A bounded miss is inconclusive.'}]};
  for (const view of ['developer', 'business', 'formal', 'evidence']) {
    const explanation = explainLaw(configured, result, view);
    assert.equal(explanation.searches, searches);
    assert.equal(explanation.assertion, law.assertion);
    assert.deepEqual(explanation.evidence, result.evidence);
    if (['business', 'formal'].includes(view)) assert.equal(explanation.text, explainLaw(law, result, view).text);
    else assert.match(explanation.text, /Configured search \(not completed evidence\): definition.amount.answer uses answers/);
  }
});

test('explanation views present composed propositions from the typed logical tree', () => {
  const exists = { kind: 'exists', binder: { id: 'a', name: 'approval', type: { kind: 'constructor', name: 'Bool', arguments: [] } },
    predicates: [], body: law.assertion };
  const disjunction = { kind: 'not', body: { kind: 'all', items: [{ kind: 'not', body: exists }, { kind: 'not', body: law.assertion }] } };
  const implication = { kind: 'not', body: { kind: 'all', items: [exists, { kind: 'not', body: law.assertion }] } };
  assert.match(explainLaw({ ...law, assertion: disjunction }, {}, 'formal').text, /\) or \(/);
  assert.match(explainLaw({ ...law, assertion: implication }, {}, 'business').text, /If \(There must exist approval/);
  assert.equal(explainLaw({ ...law, assertion: disjunction }, {}, 'business').assertion, disjunction);
});

test('LSP positions count UTF-16 units and expand parser tab columns', () => {
  const text = 'a😀b\n\t😀x\n';
  assert.deepEqual(utf16Position(text, { line: 1, column: 3 }), { line: 0, character: 3 });
  assert.deepEqual(utf16Position(text, { line: 2, column: 10 }), { line: 1, character: 3 });
});

test('contextual articles retain typed predicates, source positions and explanation meaning', async () => {
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  const line = `law selected is definition: for all (enabled :: Bool where the enabled) => enabled = true end for all end definition end law
`;
  const request = {schemaVersion: 5, languageProfile: '1.0-rc.2', verification: {layers: ['exhaustive']},
    sources: [{path: 'articles.lawspec', content: 'unit articles\n' + line + '\nend unit\n'}]};
  const worded = await compiler.check(request);
  const plain = await compiler.check({...request, sources: [{...request.sources[0], content: request.sources[0].content.replace('the enabled', 'enabled')}]});
  assert.deepEqual(worded.diagnostics, []);
  assert.deepEqual(plain.diagnostics, []);
  const predicate = worded.laws[0].inputs[0].predicates[0];
  assert.equal(predicate.text, 'enabled');
  assert.equal(predicate.node.id, worded.laws[0].inputs[0].id);
  assert.deepEqual(predicate.origin.span.start, {file: 'articles.lawspec', line: 2, column: line.indexOf('enabled', line.indexOf('the enabled')) + 1});
  for (const view of ['business', 'formal', 'evidence'])
    assert.equal(explainLaw(worded.laws[0], worded, view).text, explainLaw(plain.laws[0], plain, view).text);
  assert.equal(worded.evidence.find(e => e.stage === 'law').status, 'exhaustively-checked');
  const unselected = await compiler.check({...request, verification: {layers: []}});
  assert.deepEqual(unselected.diagnostics, []);
  assert.equal(unselected.evidence.find(e => e.stage === 'law').status, 'not-verified');
  const formatted = await compiler.format(request);
  assert.deepEqual(formatted.diagnostics, []);
  assert.match(formatted.formattedSources[0].content, /the enabled/);
  assert.deepEqual((await compiler.format({...request, sources: formatted.formattedSources})).formattedSources, formatted.formattedSources);
});

function frame(message) {
  const body = Buffer.from(JSON.stringify({ jsonrpc: '2.0', ...message }));
  return Buffer.concat([Buffer.from(`Content-Length: ${body.length}\r\n\r\n`), body]);
}
function messages(data) {
  const result = [];
  while (data.length) {
    const header = data.indexOf('\r\n\r\n');
    assert.ok(header >= 0);
    const size = Number(/Content-Length:\s*(\d+)/i.exec(data.subarray(0, header).toString())[1]);
    result.push(JSON.parse(data.subarray(header + 4, header + 4 + size).toString()));
    data = data.subarray(header + 4 + size);
  }
  return result;
}

test('LSP transport accepts split UTF-8 messages and formats unsaved source without writing it', async () => {
  const input = new PassThrough(), output = new PassThrough();
  const chunks = [];
  output.on('data', data => chunks.push(data));
  const compiler = {
    check: async request => {
      assert.equal(request.languageProfile, '1.0-rc.2');
      assert.deepEqual(request.verification.layers, []);
      return { diagnostics: [{ code: 'total', message: 'Invalid 😀 result', at: { file: request.sources[0].path, line: 1, column: 3 } }] };
    },
    format: async request => ({ diagnostics: [], formattedSources: request.sources.map(s => ({ ...s, content: s.content + '\n' })) }),
  };
  const running = serveLanguage(input, output, compiler);
  const protocol = Buffer.concat([
    frame({ id: 1, method: 'initialize', params: { rootUri: 'file:///unlikely-lawspec-test-project' } }),
    frame({ method: 'textDocument/didOpen', params: { textDocument: { uri: 'file:///unlikely-lawspec-test-project/test.lawspec', version: 1, text: 'a😀b' } } }),
    frame({ id: 2, method: 'textDocument/formatting', params: { textDocument: { uri: 'file:///unlikely-lawspec-test-project/test.lawspec' } } }),
    frame({ id: 3, method: 'shutdown' }),
  ]);
  for (let i = 0; i < protocol.length; i += 7) input.write(protocol.subarray(i, i + 7));
  input.end();
  await running;
  const responses = messages(Buffer.concat(chunks));
  assert.equal(responses.find(r => r.id === 1).result.capabilities.positionEncoding, 'utf-16');
  const diagnostic = responses.find(r => r.method === 'textDocument/publishDiagnostics').params.diagnostics[0];
  assert.equal(diagnostic.range.start.character, 3);
  assert.equal(diagnostic.code, 'total');
  assert.equal(responses.find(r => r.id === 2).result[0].newText, 'a😀b\n');
  assert.deepEqual(responses.find(r => r.id === 2).result[0].range.end, { line: 0, character: 4 });
});


test('LSP follows documentary links to original source with UTF-16 ranges and no expansion', async () => {
  const uri = 'file:///unlikely-lawspec-test-project/references.lawspec';
  const file = '/unlikely-lawspec-test-project/references.lawspec';
  const text = 'law \"|😀 source| is\n\tref law \"|😀 source|\nend\n';
  const location = (line, column) => ({ file, line, column });
  const target = { id: 'shop::law::\"|😀 source|', unit: 'shop', name: '\"|😀 source|',
    span: { spanStart: location(1, 1), spanEnd: location(1, 1) },
    referenceSpan: { spanStart: location(2, 17), spanEnd: location(2, 28) } };
  const input = new PassThrough(), output = new PassThrough(), chunks = [];
  output.on('data', data => chunks.push(data));
  const running = serveLanguage(input, output, { check: async () => ({ laws: [{ id: 'shop::law::linked', name: 'linked', location: location(3, 1), references: [{ kind: 'law', target }] }] }) });
  input.end(Buffer.concat([
    frame({ id: 1, method: 'initialize', params: { rootUri: 'file:///unlikely-lawspec-test-project' } }),
    frame({ method: 'textDocument/didOpen', params: { textDocument: { uri, version: 1, text } } }),
    frame({ id: 2, method: 'textDocument/definition', params: { textDocument: { uri }, position: { line: 1, character: 12 } } }),
    frame({ id: 3, method: 'textDocument/hover', params: { textDocument: { uri }, position: { line: 1, character: 12 } } }),
    frame({ id: 4, method: 'textDocument/references', params: { textDocument: { uri }, position: { line: 1, character: 12 }, context: { includeDeclaration: true } } }),
    frame({ id: 5, method: 'shutdown' }),
  ]));
  await running;
  const responses = messages(Buffer.concat(chunks));
  assert.deepEqual(responses.find(r => r.id === 2).result, { uri, range: { start: { line: 0, character: 0 }, end: { line: 0, character: 0 } } });
  assert.deepEqual(responses.find(r => r.id === 3).result.range, { start: { line: 1, character: 9 }, end: { line: 1, character: 21 } });
  assert.match(responses.find(r => r.id === 3).result.contents.value, /😀 source/);
  assert.equal(responses.find(r => r.id === 4).result.length, 2);
});

test('WASM-backed LSP follows unsaved documentary function and law links', async () => {
  const uri = 'file:///unlikely-lawspec-test-project/actual-references.lawspec';
  const text = `unit actual.references

function "|😀 echo| (value :: Bool) -> Bool is value end function
law linked is
  definition: true end definition
  references:
    ref function "|😀 echo|
    ref law linked description
  end references
end law

end unit
`;
  const input = new PassThrough(), output = new PassThrough(), chunks = [];
  output.on('data', data => chunks.push(data));
  // Create the real compiler before feeding a stream that can already end.
  const {createCompiler} = await import('../api.mjs');
  const running = serveLanguage(input, output, await createCompiler());
  input.end(Buffer.concat([
    frame({ id: 1, method: 'initialize', params: { rootUri: 'file:///unlikely-lawspec-test-project' } }),
    frame({ method: 'textDocument/didOpen', params: { textDocument: { uri, version: 1, text } } }),
    frame({ id: 2, method: 'textDocument/definition', params: { textDocument: { uri }, position: { line: 6, character: 21 } } }),
    frame({ id: 3, method: 'textDocument/hover', params: { textDocument: { uri }, position: { line: 6, character: 21 } } }),
    frame({ id: 4, method: 'textDocument/references', params: { textDocument: { uri }, position: { line: 7, character: 14 }, context: { includeDeclaration: true } } }),
    frame({ id: 5, method: 'shutdown' }),
  ]));
  await running;
  const responses = messages(Buffer.concat(chunks));
  assert.deepEqual(responses.find(r => r.method === 'textDocument/publishDiagnostics').params.diagnostics, []);
  assert.equal(responses.find(r => r.id === 2).result.uri, uri);
  assert.deepEqual(responses.find(r => r.id === 2).result.range.start, { line: 2, character: 0 });
  assert.deepEqual(responses.find(r => r.id === 3).result.range, { start: { line: 6, character: 17 }, end: { line: 6, character: 27 } });
  assert.equal(responses.find(r => r.id === 4).result.length, 2);
});

test('WASM-backed LSP checks and navigates witness settings in unsaved harnesses', async () => {
  const root = 'file:///unlikely-lawspec-witness-project';
  const uri = root + '/law.lawspec', harnessUri = root + '/law.harness.lawspec';
  const text = `unit example.lspWitness

function build (flag :: Bool) -> Integer is 1 end function
law selected is definition: there exists (answer :: Integer) such that answer = 1 end exists end definition end law

end unit
`;
  const header = 'harness example.lspWitness.testing for example.lspWitness is\nfor law selected\n';
  const input = new PassThrough(), output = new PassThrough(), chunks = [];
  output.on('data', data => chunks.push(data));
  const {createCompiler} = await import('../api.mjs');
  const running = serveLanguage(input, output, await createCompiler());
  input.end(Buffer.concat([
    frame({ id: 1, method: 'initialize', params: { rootUri: root } }),
    frame({ method: 'textDocument/didOpen', params: { textDocument: { uri, version: 1, text } } }),
    frame({ method: 'textDocument/didOpen', params: { textDocument: { uri: harnessUri, version: 1, text: header + 'witness false for answer\nend for law\nend harness\n' } } }),
    frame({ method: 'textDocument/didChange', params: { textDocument: { uri: harnessUri, version: 2 }, contentChanges: [{ text: header + 'witness build true for definition.answer\nend for law\nend harness\n' }] } }),
    frame({ id: 2, method: 'textDocument/definition', params: { textDocument: { uri: harnessUri }, position: { line: 2, character: 10 } } }),
    frame({ id: 3, method: 'shutdown' }),
  ]));
  await running;
  const responses = messages(Buffer.concat(chunks));
  const diagnostics = responses.filter(r => r.method === 'textDocument/publishDiagnostics' && r.params.uri === harnessUri).map(r => r.params.diagnostics);
  assert.equal(diagnostics[0].length, 1);
  assert.equal(diagnostics[0][0].code, 'harness');
  assert.deepEqual(diagnostics[0][0].range.start, { line: 2, character: 0 });
  assert.deepEqual(diagnostics.at(-1), []);
  assert.equal(responses.find(r => r.id === 2).result.uri, uri);
  assert.deepEqual(responses.find(r => r.id === 2).result.range.start, { line: 2, character: 0 });
});

test('WASM-backed LSP points to unsaved scoped strategy targets and navigates their checked calls', async () => {
  const root = 'file:///unlikely-lawspec-scoped-search-project';
  const uri = root + '/law.lawspec', harnessUri = root + '/law.harness.lawspec';
  const text = `unit example.lspSearch

function build (flag :: Bool) -> Integer is 1 end function
law selected is definition: there exists (answer :: Integer) such that answer = 1 end exists end definition end law

end unit
`;
  const strategy = 'strategy answers :: Integer is one of build true end strategy';
  const header = 'harness example.lspSearch.testing for example.lspSearch is\n' + strategy + '\nfor law selected\n';
  const input = new PassThrough(), output = new PassThrough(), chunks = [];
  output.on('data', data => chunks.push(data));
  const {createCompiler} = await import('../api.mjs');
  const running = serveLanguage(input, output, await createCompiler());
  input.end(Buffer.concat([
    frame({id: 1, method: 'initialize', params: {rootUri: root}}),
    frame({method: 'textDocument/didOpen', params: {textDocument: {uri, version: 1, text}}}),
    frame({method: 'textDocument/didOpen', params: {textDocument: {uri: harnessUri, version: 1, text: header + 'use answers for missing\nend for law\nend harness\n'}}}),
    frame({method: 'textDocument/didChange', params: {textDocument: {uri: harnessUri, version: 2}, contentChanges: [{text: header + 'use answers for definition.answer\nend for law\nend harness\n'}]}}),
    frame({id: 2, method: 'textDocument/definition', params: {textDocument: {uri: harnessUri}, position: {line: 1, character: strategy.indexOf('build') + 1}}}),
    frame({id: 3, method: 'shutdown'}),
  ]));
  await running;
  const responses = messages(Buffer.concat(chunks));
  const diagnostics = responses.filter(r => r.method === 'textDocument/publishDiagnostics' && r.params.uri === harnessUri).map(r => r.params.diagnostics);
  assert.equal(diagnostics[0].length, 1);
  assert.equal(diagnostics[0][0].code, 'harness');
  assert.deepEqual(diagnostics[0][0].range.start, {line: 3, character: 0});
  assert.deepEqual(diagnostics.at(-1), []);
  assert.equal(responses.find(r => r.id === 2).result.uri, uri);
  assert.deepEqual(responses.find(r => r.id === 2).result.range.start, {line: 2, character: 0});
});


test('canonical anonymous records reach checked definitions, literal tables and every target', async () => {
  const {createCompiler} = await import('../api.mjs');
  const {targets} = await import('../templates.mjs');
  const compiler = await createCompiler();
  const content = `unit records

function double (value of type record{count of type Integer}) -> record{count of type Integer} is
  record{count = value.count + value.count}
end function
function wrap (value of type a) -> record{wrapped of type a} is record{wrapped = value} end function
law doubles is
  definition: for all (value of type record{count of type Integer}) =>
    (double value).count must be value.count + value.count
  end for all end definition
  expect double value = expected
  in table (value, expected):
    row record{count = -1}, record{count = -2}
    row record{count = 0}, record{count = 0}
    row record{count = 1}, record{count = 2}
  end table
end law
law wraps is definition: (wrap true).wrapped = true end definition end law
law ordered is definition: record{a = 1, b = true} = record{b = true, a = 1} end definition end law
law empty is definition: record{} = record{} end definition end law

end unit
`;
  const request = {schemaVersion: 5, languageProfile: '1.0-rc.2', verification: {layers: []},
    sources: [{path: 'records.lawspec', content}]};
  for (const machineBits of [32, 64]) {
    const result = await compiler.check({...request, machineBits});
    assert.deepEqual(result.diagnostics, []);
    assert.equal(result.laws.length, 4);
    assert.equal(result.laws[0].examples.length, 3);
    assert.ok(result.evidence.filter(e => e.stage === 'law').every(e => e.status === 'not-verified'));
  }
  for (const target of targets) {
    const plan = await compiler.planGeneration({...request, target});
    assert.deepEqual(plan.diagnostics, [], target);
    assert.ok(plan.files.some(file => file.placement === 'test'), target);
  }
  const formatted = await compiler.format(request);
  assert.deepEqual(formatted.diagnostics, []);
  assert.match(formatted.formattedSources[0].content, /must be/);
  assert.equal(formatted.formattedSources[0].content.split(/\n/).filter(line => line.startsWith('law ')).length, 4);
  assert.deepEqual((await compiler.format({...request, sources: formatted.formattedSources})).formattedSources, formatted.formattedSources);
  assert.deepEqual((await compiler.check({...request, sources: formatted.formattedSources})).diagnostics, []);
});

test('anonymous record construction retains mandatory validation with no law layers', async () => {
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  for (const content of [
    `function invalid (value of type ()) -> Integer is record{safe = 1, unused = 1 / 0}.safe end function
`,
    'function invalid (value of type record{n Integer}) -> Integer is 1 end function',
    'law invalid is definition: record{n = 1, n = 2} = record{n = 1} end definition end law',
    `law invalid is definition: record{} = () end definition end law
`,
    `law invalid is definition: for all (value of type record{count of type Nat}) => value = value end for all end definition
     expect value.count = 0 in table (value): row record{count = 0} end table end law
`,
  ]) {
    const result = await compiler.check({schemaVersion: 5, languageProfile: '1.0-rc.2', verification: {layers: []},
      sources: [{path: 'invalid-record.lawspec', content: 'unit records\n' + content + '\nend unit\n'}]});
    assert.ok(result.diagnostics.length, content);
    assert.ok(result.diagnostics.every(diagnostic => !diagnostic.code.startsWith('block-')),
      JSON.stringify(result.diagnostics));
  }
});


test('nominal structural payloads preserve generic fields, table values and mandatory contracts', async () => {
  const {readFile} = await import('node:fs/promises');
  const {createCompiler} = await import('../api.mjs');
  const {targets} = await import('../templates.mjs');
  const compiler = await createCompiler();
  const path = 'examples/rc1/record-payloads.lawspec';
  const content = await readFile(new URL('../' + path, import.meta.url), 'utf8');
  const request = {schemaVersion: 5, languageProfile: '1.0-rc.2', verification: {layers: []},
    sources: [{path, content}]};
  for (const machineBits of [32, 64]) {
    const checked = await compiler.check({...request, machineBits});
    assert.deepEqual(checked.diagnostics, []);
    assert.equal(checked.laws.length, 8);
    assert.equal(checked.laws.flatMap(law => law.examples).length, 4);
    const boxes = checked.laws.find(law => law.name === 'boxedRows').examples;
    assert.deepEqual(boxes.map(row => String.fromCodePoint(...row.bindings[0].value.fields[0].fields[0].units)), ['note', 'paper']);
    assert.ok(checked.evidence.filter(item => item.stage === 'law').every(item => item.status === 'not-verified'));
    for (const target of targets) {
      const plan = await compiler.planGeneration({...request, machineBits, target});
      assert.deepEqual(plan.diagnostics, [], target);
      assert.ok(plan.files.some(file => file.placement === 'test'), target);
    }
  }
  const formatted = await compiler.format(request);
  assert.deepEqual(formatted.diagnostics, []);
  for (const [keyword, count] of [['type', 4], ['function', 5], ['law', 8]])
    assert.equal(formatted.formattedSources[0].content.split(/\n/).filter(line => line.startsWith(keyword + ' ')).length, count);
  assert.deepEqual((await compiler.format({...request, sources: formatted.formattedSources})).formattedSources, formatted.formattedSources);
  for (const invalid of [
    content.replace('height = 3', 'height = 0'),
    content + '\nfunction invalid (ignored of type ()) -> Box Integer is Box record{value = 1 / 0} end function\n',
  ]) {
    assert.notEqual(invalid, content);
    const checked = await compiler.check({...request, sources: [{path, content: invalid}]});
    assert.ok(checked.diagnostics.length, 'definition contracts remain mandatory with no law layers');
  }
});


test('generic record refinements and named-record tables preserve mandatory checks through the public API', async () => {
  const {readFile} = await import('node:fs/promises');
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  const path = 'examples/rc1/parcel-measurements.lawspec';
  const content = await readFile(new URL('../' + path, import.meta.url), 'utf8');
  const request = {schemaVersion: 5, languageProfile: '1.0-rc.2', verification: {layers: []},
    sources: [{path, content}]};
  for (const machineBits of [32, 64]) {
    const checked = await compiler.check({...request, machineBits});
    assert.deepEqual(checked.diagnostics, []);
    assert.equal(checked.laws.length, 3);
    assert.equal(checked.laws.flatMap(law => law.examples).length, 4);
    const weights = checked.laws.find(law => law.name === 'positiveWeights').examples;
    assert.deepEqual(weights.map(row => row.bindings[0].value.fields[0].fields[0].fields[0].value), ['1', '3']);
    const labels = checked.laws.find(law => law.name === 'recipientLabels').examples;
    assert.deepEqual(labels.map(row => String.fromCodePoint(...row.bindings[0].value.fields[0].fields[0].fields[1].units)), ['Asha', 'Bo']);
    assert.ok(checked.evidence.filter(item => item.stage === 'law').every(item => item.status === 'not-verified'));
    const selected = await compiler.check({...request, machineBits, verification: {layers: ['exhaustive']}});
    assert.deepEqual(selected.diagnostics, []);
    assert.equal(selected.evidence.find(item => item.stage === 'law' && item.declaration.endsWith('::sampleWeight')).status, 'exhaustively-checked');
    assert.ok(selected.evidence.filter(item => item.stage === 'law' && !item.declaration.endsWith('::sampleWeight')).every(item => item.status === 'incomplete'));
    for (const target of ['python', 'javascript']) {
      const plan = await compiler.planGeneration({...request, machineBits, target});
      assert.deepEqual(plan.diagnostics, [], target);
      assert.ok(plan.files.some(file => file.placement === 'test'), target);
    }
  }
  const formatted = await compiler.format(request);
  assert.deepEqual(formatted.diagnostics, []);
  assert.deepEqual((await compiler.format({...request, sources: formatted.formattedSources})).formattedSources, formatted.formattedSources);
  assert.deepEqual((await compiler.check({...request, sources: formatted.formattedSources})).diagnostics, []);
  for (const invalid of [
    content.replace('value = 1', 'value = 0'),
    content.replace('row record{weight = Measurement record{reading = record{value = 1}}}, 1',
      'row record{weight = Measurement record{reading = record{value = 0}}}, 0'),
  ]) {
    assert.notEqual(invalid, content);
    assert.ok((await compiler.check({...request, sources: [{path, content: invalid}]})).diagnostics.length,
      'intrinsic field restrictions remain mandatory with no law layers');
  }
});

test('developer explanations retain concrete table inputs and every typed expectation', async () => {
  const {createCompiler} = await import('../api.mjs');
  const {readFile} = await import('node:fs/promises');
  const compiler = await createCompiler();
  const content = await readFile(new URL('../starter-rc1.lawspec', import.meta.url), 'utf8');
  const result = await compiler.expand({schemaVersion: 5, languageProfile: '1.0-rc.2',
    sources: [{path: 'starter.lawspec', content}]});
  assert.deepEqual(result.diagnostics, []);
  const law = result.laws[0];
  assert.equal(law.examples.length, 3);
  for (const view of ['developer', 'business', 'formal', 'evidence']) {
    const shown = explainLaw(law, result, view);
    assert.equal(shown.examples, law.examples);
    assert.equal(shown.assertion, law.assertion);
  }
  const text = explainLaw(law, result, 'developer').text;
  assert.match(text, /x = -42/);
  assert.match(text, /expect itoa -42 = "-42"/);
  assert.match(text, /expect atoi "-42" = -42/);
  assert.equal((text.match(/  expect /g) ?? []).length, 6);
  assert.equal(result.evidence.filter(item => item.stage === 'law')[0].status, 'not-verified');
});


test('fmt explicit paths use the working directory even when a different configuration directory is supplied',async()=>{
  const {mkdtemp,mkdir,writeFile,readFile,rm}=await import('node:fs/promises');
  const {spawnSync}=await import('node:child_process');
  const {default:path}=await import('node:path');const {default:os}=await import('node:os');
  const outer=await mkdtemp(path.join(os.tmpdir(),'lawspec-fmt-root-'));
  try{
    const root=path.join(outer,'project');await mkdir(path.join(root,'config'),{recursive:true});
    const source=`unit sample

function same (value :: Bool) -> Bool is
value
end function

end unit
`;
    await writeFile(path.join(root,'sample.lawspec'),source);
    await writeFile(path.join(outer,'sample.lawspec'),'unrelated sibling file\n');
    await writeFile(path.join(root,'config/lawspec.json'),JSON.stringify({version:2,languageProfile:'1.0-rc.2',
      sources:['../sample.lawspec'],targets:[],verification:{layers:[]}}));
    const cli=new URL('../bin/lawspec.mjs',import.meta.url).pathname;
    const run=args=>spawnSync(process.execPath,[cli,'fmt','sample.lawspec','--config','config/lawspec.json','--json',...args],
      {cwd:root,encoding:'utf8'});
    const needed=run(['--check']);assert.equal(needed.status,1,needed.stdout+needed.stderr);
    assert.deepEqual(JSON.parse(needed.stdout).changed,['sample.lawspec']);
    const written=run([]);assert.equal(written.status,0,written.stdout+written.stderr);
    assert.notEqual(await readFile(path.join(root,'sample.lawspec'),'utf8'),source);
    assert.equal(await readFile(path.join(outer,'sample.lawspec'),'utf8'),'unrelated sibling file\n');
    const checked=run(['--check']);assert.equal(checked.status,0,checked.stdout+checked.stderr);
    assert.deepEqual(JSON.parse(checked.stdout).changed,[]);
  }finally{await rm(outer,{recursive:true,force:true});}
});

test('indexed record inputs retain intrinsic guards and complete finite law domains in the SDK', async () => {
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  const source = `unit levels

type Level (n of type Whole) is one of | Low where n = 0 | High where n = 1 end type
function measured (pair of type record{left of type Level m right of type Level m}) -> Whole is nOfLevel pair.left end function
law same is definition: for all (pair of type record{left of type Level m right of type Level m}) =>
measured pair must be nOfLevel pair.right end for all end definition
expect measured pair = expected in table (pair,expected): row record{left = Low, right = Low}, 0 row record{left = High, right = High}, 1 end table end law

end unit
`;
  for (const machineBits of [32, 64]) {
    const input = {schemaVersion: 5, languageProfile: '1.0-rc.2', machineBits,
      sources: [{path: 'levels.lawspec', content: source}]};
    const unchecked = await compiler.check({...input, verification: {layers: []}});
    assert.deepEqual(unchecked.diagnostics, []);
    assert.equal(unchecked.verification.selection, 'no-selected-checks');
    assert.equal(unchecked.evidence.filter(item => item.stage === 'law').length, 1);
    assert.ok(unchecked.evidence.filter(item => item.stage === 'law').every(item => item.status === 'not-verified'));
    const record = unchecked.dataTypes.find(type => type.structure?.indexGuards?.length);
    assert.deepEqual(record.structure.indexGuards, ['== f0 f1']);
    assert.match(record.structure.descriptor, /lawspec\.record\.v2/);
    const checked = await compiler.check({...input, verification: {layers: ['exhaustive', 'examples']}});
    assert.deepEqual(checked.diagnostics, []);
    assert.equal(checked.evidence.filter(item => item.stage === 'law').length, 1);
    assert.ok(checked.evidence.filter(item => item.stage === 'law').every(item => item.status === 'exhaustively-checked'));
    const unconstrained = source.replaceAll('right of type Level m', 'right of type Level k');
    const failed = await compiler.check({...input,
      sources: [{path: 'levels.lawspec', content: unconstrained}], verification: {layers: ['exhaustive', 'examples']}});
    assert.ok(failed.diagnostics.some(item => item.code === 'refuted'));
  }
});


test('the SDK retains two indices of one record field as a type-owned relationship', async () => {
  const {createCompiler} = await import('../api.mjs');
  const compiler = await createCompiler();
  const source = `unit dimensions

type Matrix (rows of type Whole) (columns of type Whole) is one of | Zero where rows = 0, columns = 0 | Skew where rows = 0, columns = 1 | One where rows = 1, columns = 1 end type
law diagonal is definition: for all (pair of type record{matrix of type Matrix dimension dimension}) => rowsOfMatrix pair.matrix must be columnsOfMatrix pair.matrix end for all end definition end law

end unit
`;
  for (const machineBits of [32, 64]) {
    const input = {schemaVersion: 5, languageProfile: '1.0-rc.2', machineBits,
      verification: {layers: ['exhaustive']}, sources: [{path: 'dimensions.lawspec', content: source}]};
    const result = await compiler.check(input);
    assert.deepEqual(result.diagnostics, []);
    const records = result.dataTypes.filter(type => type.structure?.indexGuards?.length);
    assert.equal(records.length, 1);
    assert.deepEqual(records[0].structure.indexGuards, ['== f0 f0.1']);
    const laws = result.evidence.filter(item => item.stage === 'law');
    assert.equal(laws.length, 1);
    assert.equal(laws[0].status, 'exhaustively-checked');
    const independent = await compiler.check({...input, sources: [{path: 'dimensions.lawspec',
      content: source.replaceAll('Matrix dimension dimension', 'Matrix dimension independent')}]});
    assert.ok(independent.diagnostics.some(item => item.code === 'refuted'));
    const make = tag => source.split('law diagonal')[0] +
      'function make (ignored of type Bool) -> record{matrix of type Matrix dimension dimension} is ' +
      'record{matrix = ' + tag + '} end function\nend unit';
    const admitted = await compiler.check({...input, verification: {layers: []},
      sources: [{path: 'dimensions.lawspec', content: make('Zero')}]});
    assert.deepEqual(admitted.diagnostics, []);
    const rejected = await compiler.check({...input, verification: {layers: []},
      sources: [{path: 'dimensions.lawspec', content: make('Skew')}]});
    assert.ok(rejected.diagnostics.some(item => item.code === 'total'));
  }
});
