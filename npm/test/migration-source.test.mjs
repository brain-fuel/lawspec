// Generated from templates/npm/test/migration-source.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {migrationTokens, migrationOffset, MigrationDocument, planLegacyComputationEdits} from '../migration-source.mjs';
import {createCompiler} from '../api.mjs';
import {migrationReport,legacyLawLayers} from '../migrate.mjs';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {mkdtemp, readFile, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {fileURLToPath} from 'node:url';
const legacyOptions={schemaVersion:5,languageProfile:'1.0-rc.1',from:'0.24',verification:{layers:legacyLawLayers}};

test('migration tokens retain comments, quoted names, literal escapes and Unicode exactly', () => {
  const text = 'unit sample\r\n-- end "text"\r\n`a law` "end \\" | 😀" + \'\'\t:: ->\n';
  const tokens = migrationTokens(text);
  assert.equal(tokens.map(token => token.text).join(''), text);
  assert.deepEqual(tokens.filter(token => token.kind === 'comment').map(token => token.text), ['-- end "text"\r']);
  assert.equal(tokens.find(token => token.kind === 'quoted').text, '`a law`');
  assert.equal(tokens.find(token => token.kind === 'string').text, '"end \\" | 😀"');
  for (const token of tokens) assert.equal(text.slice(token.start, token.end), token.text);
  assert.throws(() => migrationTokens('"unfinished'), /Unterminated/);
  assert.throws(() => migrationTokens('`unfinished'), /Unterminated/);
});

test('migration offsets translate parser code-point and tab columns into UTF-16 offsets', () => {
  const text = 'a😀b\r\n\t😀x\n';
  assert.equal(migrationOffset(text, {line:1,column:3}), 3);
  assert.equal(migrationOffset(text, {line:2,column:9}), 7);
  assert.equal(migrationOffset(text, {line:2,column:10}), 9);
  assert.equal(migrationOffset(text, {line:3,column:1}), text.length);
  assert.throws(() => migrationOffset(text, {line:2,column:2}), /inside a tab/);
  assert.throws(() => migrationOffset(text, {line:3,column:2}), /out of bounds/);
  assert.throws(() => migrationOffset(text, {line:4,column:1}), /out of bounds/);
});

test('migration edits reject overlap, deduplicate specialization copies and retain origin segments', () => {
  const document = new MigrationDocument({path:'sample',content:'abc def'});
  document.edit(0,3,'function','declaration');
  document.edit(0,3,'function','declaration');
  assert.throws(() => document.edit(1,2,'x','conflict'), /Overlapping/);
  assert.throws(() => document.edit(1,1,'x','insertion'), /Overlapping/);
  document.edit(7,7,' end if','conditional','first');
  document.edit(7,7,' end if','conditional','second');
  const result = document.result();
  assert.equal(result.content, 'function def end if end if');
  assert.equal(result.edits.length, 3);
  for (const segment of result.segments.filter(segment => segment.retained))
    assert.equal(result.content.slice(segment.start,segment.end), document.content.slice(segment.originalStart,segment.originalEnd));
});

function semantic(value) {
  if (Array.isArray(value)) return value.map(semantic);
  if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value)
    .filter(([key]) => !['origin','text'].includes(key)).map(([key,item]) => [key,semantic(item)]));
  return value;
}

test('typed migration preserves nested conditional bodies, Unicode comments and reserved-prefix literals', async () => {
  const compiler = await createCompiler();
  const content = 'unit sample\n-- 😀 keep if then else end as documentary text\n' +
    'definition choose (enabled :: Bool) :: Text is\n' +
    '  (if enabled then "|123" else (if enabled then "-- end" else "\\\\end")) -- after body\nend\n';
  for (const machineBits of [32,64]) {
    const source = {path:'sample.lawspec',content};
    const before = await compiler.migrationBaseline({...legacyOptions,machineBits,sources:[source]});
    assert.deepEqual(before.diagnostics, []);
    const [planned] = planLegacyComputationEdits([source], before);
    assert.match(planned.content, /^function choose/m);
    assert.match(planned.content, /\) -> Text is/);
    assert.match(planned.content, /end function/);
    assert.equal(planned.edits.filter(edit => edit.reason === 'conditional closer').length, 2);
    assert.ok(planned.content.includes('-- 😀 keep if then else end as documentary text'));
    assert.ok(planned.content.includes('-- after body'));
    assert.ok(planned.content.includes('"\\124\\49\\50\\51"'));
    const after = await compiler.check({schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]},machineBits,
      sources:[{path:source.path,content:planned.content}]});
    assert.deepEqual(after.diagnostics, [], planned.content);
    assert.deepEqual(semantic(after.definitions), semantic(before.definitions));
    assert.deepEqual(after.verification.intrinsicDefinitionChecks, true);
  }
});

test('effectful definitions migrate to procedures using the checked effect row', async () => {
  const compiler = await createCompiler();
  const source = {path:'effects.lawspec',content:'unit effects\nability Clock is tick :: Bool -> Bool end\n' +
    'definition tickOnce (value :: Bool) :: Bool uses Clock is tick value end\n'};
  for (const content of [source.content,source.content.replace('uses Clock ','')]) {
    const original = {...source,content};
    const before = await compiler.migrationBaseline({...legacyOptions,sources:[original]});
    assert.deepEqual(before.diagnostics, []);
    const [planned] = planLegacyComputationEdits([original], before);
    assert.match(planned.content, /procedure tickOnce/);
    assert.match(planned.content, /end procedure/);
    const after = await compiler.check({schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]},sources:[{path:source.path,content:planned.content}]});
    assert.deepEqual(after.diagnostics, []);
    assert.deepEqual(semantic(after.definitions), semantic(before.definitions));
    assert.deepEqual(semantic(after.units), semantic(before.units));
  }
});

test('equality edits come from typed Boolean, IEEE and refinement expressions while literal spellings stay intact', async () => {
  const compiler = await createCompiler();
  const source = {path:'equality.lawspec',content:'unit equality\n' +
    '-- == remains documentary text\n' +
    'definition equal (left :: Bool) (right :: Bool) :: Bool is left == right end\n' +
    'definition ieee (left :: Float64) (right :: Float64) :: Bool is left == right end\n' +
    'definition same (value :: Int8) :: (result :: Int8 where result == value) is value end\n' +
    'definition text (unused :: Bool) :: Text is "==" end\n'};
  for (const machineBits of [32,64]) {
    const before = await compiler.migrationBaseline({...legacyOptions,machineBits,sources:[source]});
    assert.deepEqual(before.diagnostics, []);
    const [planned] = planLegacyComputationEdits([source],before);
    assert.equal(planned.edits.filter(edit => edit.reason === 'typed equality').length, 3);
    assert.ok(planned.content.includes('-- == remains documentary text'));
    assert.ok(planned.content.includes('"=="'));
    const after = await compiler.check({schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]},machineBits,
      sources:[{path:source.path,content:planned.content}]});
    assert.deepEqual(after.diagnostics, [], planned.content);
    assert.deepEqual(semantic(after.definitions), semantic(before.definitions));
    assert.deepEqual(semantic(after.contracts), semantic(before.contracts));
  }
});

test('typed equality remains discoverable after intrinsic calls and nullary constructors are lowered', async () => {
  const compiler = await createCompiler();
  const source = {path:'lowered.lawspec',content:'unit lowered\n' +
    'definition missing (value :: Maybe Bool) :: Bool is value == Nothing end\n' +
    'definition even (value :: UInt8) :: Bool is prelude.rem value 2 == 0 end\n' +
    'definition choose (value :: UInt8) :: Bool is if prelude.rem value 2 == 0 then true else false end\n'};
  for (const machineBits of [32,64]) {
    const before = await compiler.migrationBaseline({...legacyOptions,machineBits,sources:[source]});
    assert.deepEqual(before.diagnostics, []);
    const [planned] = planLegacyComputationEdits([source],before);
    assert.equal(planned.edits.filter(edit => edit.reason === 'typed equality').length, 3);
    const after = await compiler.check({schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]},machineBits,
      sources:[{path:source.path,content:planned.content}]});
    assert.deepEqual(after.diagnostics, [], planned.content);
    assert.deepEqual(semantic(after.definitions),semantic(before.definitions));
  }
});

test('migration requires a checked baseline and refuses inconsistent source identities', () => {
  assert.throws(() => planLegacyComputationEdits([], {diagnostics:[{code:'total'}]}), /checked legacy/);
  assert.throws(() => planLegacyComputationEdits([{path:'a',content:''},{path:'a',content:''}], {diagnostics:[]}), /Duplicate/);
  const document = new MigrationDocument({path:'a',content:'abc'});
  assert.equal(document.range({kind:'source',span:{start:{file:'b',line:1,column:1},end:{file:'b',line:1,column:2}}}), null);
  assert.throws(() => document.range({kind:'source',span:{start:{file:'a',line:1,column:3},end:{file:'a',line:1,column:2}}}), /Reversed/);
});

test('read-only migration exposes validated original spans and edits without writing', async () => {
  const compiler = await createCompiler();
  const source = {path:'report.lawspec',content:'unit report\ndefinition identity (value :: Bool) :: Bool is value end\n'};
  const report = await migrationReport(compiler,{version:1,targets:[]},{sources:[source],machineBits:64});
  assert.equal(report.validated, true);
  assert.deepEqual(report.filesWritten, []);
  assert.deepEqual(report.sourcePreview.diagnostics, []);
  assert.equal(report.baseline.definitions.length, 1);
  assert.equal(report.sourcePreview.sources.length, 1);
  assert.equal(report.sourcePreview.sources[0].edits.length, 3);
  assert.equal(report.sourcePreview.sources[0].content, 'unit report\nfunction identity (value :: Bool) -> Bool is value end function\n');
  assert.equal(source.content, 'unit report\ndefinition identity (value :: Bool) :: Bool is value end\n');
  assert.deepEqual(report.blockers,[]);
});

test('source inventory migrates unused generic computation bodies before concrete specialization exists', async () => {
  const compiler = await createCompiler();
  const source = {path:'generic.lawspec',content:'unit generic\n' +
    'definition same (left :: a) (right :: a) :: Bool requires Eq a is if left == right then left == right else false end\n'};
  const report = await migrationReport(compiler,{version:1,targets:[]},{sources:[source],machineBits:64});
  assert.deepEqual(report.diagnostics, []);
  assert.deepEqual(report.sourcePreview.diagnostics, []);
  assert.equal(report.baseline.definitions.length, 0);
  assert.ok(report.baseline.sourceSyntax[0].nodes.some(node => node.kind === 'declaration.definition' && node.name === 'same'));
  const planned = report.sourcePreview.sources[0];
  assert.match(planned.content,/function same/);
  assert.equal(planned.edits.filter(edit => edit.reason === 'typed equality').length,2);
  assert.equal(planned.edits.filter(edit => edit.reason === 'conditional closer').length,1);
  const before = await compiler.migrationBaseline({...legacyOptions,sources:[source,{path:'use.lawspec',content:
    'unit use\nimport generic as generic (same)\nlaw `truth` is definition is `for all` (a :: Bool) (b :: Bool) . generic.same a b = (a == b) end end'}]});
  const after = await compiler.check({schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:['exhaustive']},sources:[
    {path:source.path,content:planned.content},{path:'use.lawspec',content:
      'unit use\nimport generic as generic (same)\nlaw truth is definition: for all (a :: Bool) (b :: Bool) => generic.same a b = (a = b) end end end'}]});
  assert.deepEqual(before.diagnostics, []);
  assert.deepEqual(after.diagnostics, []);
  assert.deepEqual(semantic(after.definitions),semantic(before.definitions));
  assert.equal(after.evidence.find(item => item.stage === 'law').status,'exhaustively-checked');
  assert.equal(report.validated,true,JSON.stringify(report.blockers));
});

test('source inventory preserves inferred effects when an unused generic procedure has no Core instance', async () => {
  const compiler = await createCompiler();
  const source = {path:'effects.lawspec',content:'unit effects\nability Clock is tick :: Bool -> Bool end\n' +
    'definition observed (value :: a) :: a is tick true; value end\n'};
  const report = await migrationReport(compiler,{version:1,targets:[]},{sources:[source]});
  assert.deepEqual(report.diagnostics, []);
  assert.deepEqual(report.sourcePreview.diagnostics, []);
  assert.equal(report.baseline.definitions.length,0);
  const planned = report.sourcePreview.sources[0];
  assert.match(planned.content,/procedure observed/);
  assert.match(planned.content,/end procedure/);
  const checked = await compiler.check({schemaVersion:5,languageProfile:'1.0-rc.1',verification:{layers:[]},sources:[{path:source.path,content:planned.content}]});
  assert.deepEqual(checked.diagnostics, []);
  assert.equal(checked.verification.intrinsicDefinitionChecks,true);
});

test('the migration CLI reports the computation preview and writes only on explicit request', async () => {
  const directory = await mkdtemp(join(tmpdir(),'lawspec-source-migration-'));
  try {
    const configPath = join(directory,'lawspec.json');
    const sourcePath = join(directory,'sample.lawspec');
    const config = JSON.stringify({version:1,sources:['sample.lawspec'],targets:[]});
    const source = 'unit sample\ndefinition identity (value :: Bool) :: Bool is value end\n';
    await writeFile(configPath,config);
    await writeFile(sourcePath,source);
    const args = [fileURLToPath(new URL('../bin/lawspec.mjs',import.meta.url)),'migrate','--from','0.24','--config',configPath,'--json'];
    const run = promisify(execFile);
    const result = await run(process.execPath,args,{cwd:directory});
    const report = JSON.parse(result.stdout);
    assert.equal(report.validated, true);
    assert.deepEqual(report.sourcePreview.diagnostics, []);
    assert.match(report.sourcePreview.sources[0].content,/function identity/);
    assert.equal(await readFile(configPath,'utf8'),config);
    assert.equal(await readFile(sourcePath,'utf8'),source);
    const written=JSON.parse((await run(process.execPath,[...args,'--write'],{cwd:directory})).stdout);
    assert.deepEqual(written.filesWritten,['sample.lawspec','lawspec.json']);
    assert.equal(JSON.parse(await readFile(configPath,'utf8')).version,2);
    assert.equal(await readFile(sourcePath,'utf8'),report.sourcePreview.sources[0].content);
  } finally { await rm(directory,{recursive:true,force:true}); }
});
