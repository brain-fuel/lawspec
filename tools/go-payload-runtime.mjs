// Framework-independent Go traversal, with compiled behavioral mutants.
import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const directory = path.join(root, '.artifacts/go-payload-runtime');
await mkdir(directory, {recursive: true});
const env = {...process.env, GOCACHE: path.join(root, '.artifacts/go-cache'),
  GOTOOLCHAIN: 'local', GOPROXY: 'off'};
const sources = new Map();
for (const name of ['lawspec_runtime.go', 'lawspec_schema.go']) {
  const source = (await readFile(path.join(root, 'runtime', name), 'utf8'))
    .replace('package RUNTIME_PACKAGE', 'package fixture');
  assert.equal(execFileSync('gofmt', [], {input: source, encoding: 'utf8'}), source);
  sources.set(name, source);
}
const check = await readFile(path.join(root, 'test/runtime/GoPayloadCheck.go'), 'utf8');
assert.equal(execFileSync('gofmt', [], {input: check, encoding: 'utf8'}), check);
async function setup(name, files) {
  const project = path.join(directory, name);
  await mkdir(project, {recursive: true});
  await writeFile(path.join(project, 'go.mod'), 'module fixture\n\ngo 1.24.0\n');
  for (const [filename, source] of files) await writeFile(path.join(project, filename), source);
  await writeFile(path.join(project, 'payload_test.go'), check);
  return project;
}
function run(project) {
  return spawnSync('go', ['test', '-count=1', '-v', './...'],
    {cwd: project, env, encoding: 'utf8', timeout: 60000});
}
const baseline = run(await setup('baseline', sources));
assert.equal(baseline.error, undefined);
assert.equal(baseline.status, 0, baseline.stdout + baseline.stderr);
const original = sources.get('lawspec_schema.go');
for (const [name, before, after] of [
  ['parameter', 'return arguments[t.parameter]', 'return arguments[0]'],
  ['fixed', 'if !stored {\n\t\treturn nil', 'if !stored {\n\t\treturn &lawSpecPayloadPlan{parameter: 0}'],
  ['validation', 'checked := s.validate(t, value, bits, contexts...)', 'checked := value'],
  ['accept-all', 'return lsBool(s.walkPayload(&lawSpecPayloadPlan{name: t.name, arguments: arguments}, checked, predicates))',
    '_ = checked\n\treturn lsBool(true)'],
  ['symbols', 'checked := s.validate(t, value, bits, contexts...)', 'checked := s.validate(t, value, bits)'],
  ['snapshot', 'predicates = append([]func(LawSpecValue) LawSpecValue{}, predicates...)', '// Mutant retains caller-owned callbacks.'],
]) {
  assert.ok(original.includes(before), name);
  const changed = new Map(sources);
  changed.set('lawspec_schema.go', original.replace(before, after));
  const project = await setup(name, changed);
  const result = run(project);
  const log = result.stdout + result.stderr;
  await writeFile(path.join(project, 'check.log'), log);
  assert.equal(result.error, undefined, name);
  assert.notEqual(result.status, 0, name);
  assert.match(log, /--- FAIL: TestPayload/, 'mutant must compile and fail a payload test');
}
const compiler = process.env.LAWSPEC_CORE;
if (compiler) for (const bits of [32, 64]) for (const minify of [false, true]) {
  const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target: 'go', machineBits: bits, minify,
    sources: [{path: 'payload.lawspec', content: 'unit payload\ntype Box (a :: Type) is Box value :: a end\nf :: Int8 -> Int8\nlaw `identity` is definition is `for all` (x :: Int8) . f x = x end end\n'}],
  }), encoding: 'utf8', maxBuffer: 64 * 1024 * 1024}));
  assert.deepEqual(result.diagnostics, []);
  const generated = new Map();
  for (const name of sources.keys()) {
    const artifact = result.files.find(file => path.basename(file.path) === name);
    assert.ok(artifact, name);
    generated.set(name, artifact.content.replace(/^package \w+/m, 'package fixture'));
  }
  const project = await setup(`${bits}-${minify}`, generated);
  const tested = run(project);
  await writeFile(path.join(project, 'check.log'), tested.stdout + tested.stderr);
  assert.equal(tested.error, undefined);
  assert.equal(tested.status, 0, tested.stdout + tested.stderr);
}
console.log('Go payload runtime passes both profiles, six compiled mutants, and gofmt' +
  (compiler ? '; generated readable/compact runtimes pass at both widths' : ''));
