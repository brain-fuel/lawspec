// Compile independent Haskell runtime checks and behavioral mutations.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const ghc = process.env.LAWSPEC_GHC;
assert.ok(ghc, 'Set LAWSPEC_GHC');
const directory = path.join(root, '.artifacts/haskell-payload-runtime');
const runtime = await readFile(path.join(root, 'runtime/LawSpecRuntime.hs'), 'utf8');
const schema = await readFile(path.join(root, 'runtime/LawSpecSchema.hs'), 'utf8');
const check = await readFile(path.join(root, 'test/runtime/HaskellPayloadCheck.hs'), 'utf8');
const args = ['--make', 'Main.hs', '-O0', '-i.', '-outputdir', 'build', '-o', 'check'];
if (process.env.LAWSPEC_GHC_PACKAGE_DB) args.push('-package-db', process.env.LAWSPEC_GHC_PACKAGE_DB);
async function run(name, runtimeSource, schemaSource, fail = false) {
  const project = path.join(directory, name);
  await mkdir(project, {recursive: true});
  for (const [file, content] of [['LawSpecRuntime.hs', runtimeSource],
    ['LawSpecSchema.hs', schemaSource], ['Main.hs', check]])
    await writeFile(path.join(project, file), content);
  execFileSync(ghc, args, {cwd: project, encoding: 'utf8'});
  const result = spawnSync(path.join(project, 'check'), [],
    {cwd: project, encoding: 'utf8', timeout: 60000});
  const log = (result.stdout ?? '') + (result.stderr ?? '');
  await writeFile(path.join(project, 'check.log'), log);
  assert.equal(result.error, undefined, name);
  if (fail) assert.notEqual(result.status, 0, `mutant ${name} must fail execution`);
  else assert.equal(result.status, 0, log);
}
await run('baseline', runtime, schema);
for (const [name, before, after] of [
  ['parameter', 'payloadRecipe arguments (Parameter index) = arguments !! index',
    'payloadRecipe arguments (Parameter index) = arguments !! 0'],
  ['fixed', 'if all ignored plans then IgnorePayload', 'if all ignored plans then PayloadSlot 0'],
  ['validation', 'checked <- validateWith scope schema typeRef bits value\n  LS.SBool <$> walk',
    'let checked = value\n  LS.SBool <$> walk'],
  ['accept-all', 'LS.SBool <$> walk', 'const (LS.SBool True) <$> walk'],
  ['symbols', 'checked <- validateWith scope schema typeRef bits value\n  LS.SBool <$> walk',
    'checked <- validateWith Nothing schema typeRef bits value\n  LS.SBool <$> walk'],
  ['short-circuit', 'if accepted then every steps else Right False',
    'if accepted then every steps else every steps >> Right False'],
]) {
  assert.ok(schema.includes(before), name);
  await run(name, runtime, schema.replace(before, after), true);
}
const compiler = process.env.LAWSPEC_CORE;
if (compiler) for (const bits of [32, 64]) for (const minify of [false, true]) {
  const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target: 'haskell', machineBits: bits, minify,
    sources: [{path: 'payload.lawspec', content: 'unit payload\nf :: Int8 -> Int8\nlaw `identity` is definition is `for all` (x :: Int8) . f x = x end end\n'}],
  }), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024}));
  assert.deepEqual(result.diagnostics, []);
  const source = name => {
    const artifact = result.files.find(file => path.basename(file.path) === name);
    assert.ok(artifact, name);
    return artifact.content;
  };
  await run(`${bits}-${minify}`, source('LawSpecRuntime.hs'), source('LawSpecSchema.hs'));
}
console.log('Haskell payload runtime passes both widths and six compiled mutants' +
  (compiler ? '; generated readable/compact runtimes pass at both widths' : ''));
