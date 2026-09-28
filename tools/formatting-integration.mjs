import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir, mkdtemp, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {tmpdir} from 'node:os';
import {applyWrites, digest, planWrites} from '../npm/files.mjs';
import {targets} from '../npm/templates.mjs';

const compiler = process.env.LAWSPEC_CORE;
assert.ok(compiler, 'Set LAWSPEC_CORE to the native compiler');
const definitions = await readFile(new URL('../examples/specs/total_functions.lawspec', import.meta.url), 'utf8');
const adapterSource = (element) => `unit formatting_adapter
longAdapter :: ${Array(10).fill(`List ${element}`).join(' -> ')}
`;
const call = (request) => JSON.parse(execFileSync(compiler, [], {
  input: JSON.stringify({method: 'planGeneration', ...request}),
  encoding: 'utf8',
  maxBuffer: 32 * 1024 * 1024,
}));
const files = (request) => {
  const result = call(request);
  assert.deepEqual(result.diagnostics, []);
  return result.files;
};
const temporary = await mkdtemp(path.join(tmpdir(), 'lawspec-format-'));
for (const target of targets) {
  const request = {
    target,
    sourceDir: 'generated',
    testDir: 'generated',
    sources: [
      {path: 'definitions.lawspec', content: definitions},
      {path: 'adapter.lawspec', content: adapterSource('Text')},
    ],
  };
  const readable = files(request);
  assert.deepEqual(files({...request, minify: false}), readable);
  const compact = files({...request, minify: true});
  assert.deepEqual(compact.map((a) => [a.path, a.ownership, a.placement]),
    readable.map((a) => [a.path, a.ownership, a.placement]));
  assert.ok(compact.reduce((n, a) => n + a.content.length, 0) <
    readable.reduce((n, a) => n + a.content.length, 0));
  const adapters = readable.filter((a) => a.ownership === 'user');
  assert.ok(adapters.length > 0);
  const width = ['python', 'javascript', 'typescript', 'haskell'].includes(target) ? 80 : 100;
  for (const artifact of adapters) {
    assert.ok(artifact.content.split('\n').every((line) => line.replaceAll('\t', '        ').length <= width),
      `${target}: readable adapter exceeds ${width} columns`);
  }
  assert.ok(adapters.some((a) => compact.find((b) => b.path === a.path).content !== a.content),
    `${target}: long adapter signature should honor compact rendering`);
  for (const a of adapters) {
    assert.equal(a.adapterReference, a.content);
    assert.equal(compact.find((b) => b.path === a.path).adapterReference, a.content);
  }
  assert.ok(call({...request, minify: 'true'}).diagnostics.some((d) => d.code === 'request'));

  const root = path.join(temporary, target);
  await mkdir(root);
  // A version-1 manifest from an older compiler has no reference metadata.
  const legacy = readable.map(({adapterReference, ...artifact}) => artifact);
  await applyWrites([await planWrites(root, legacy)]);
  const compactRoot = path.join(temporary, `${target}-compact-first`);
  await mkdir(compactRoot);
  await applyWrites([await planWrites(compactRoot, compact)]);
  const readablePlan = await planWrites(compactRoot, readable);
  assert.deepEqual(readablePlan.adapterUpdates, []);
  await applyWrites([readablePlan]);
  for (const a of compact.filter((a) => a.ownership === 'user')) {
    assert.equal(await readFile(path.join(compactRoot, a.path), 'utf8'), a.content);
  }
  await assert.rejects(planWrites(compactRoot, [{...adapters[0], adapterReference: 42}]),
    /Invalid adapter reference/);
  const adapter = adapters.find((a) => a.path.toLowerCase().includes('formatting'));
  assert.ok(adapter);
  const implementation = adapter.content + '\n';
  await writeFile(path.join(root, adapter.path), implementation);
  const compactPlan = await planWrites(root, compact);
  assert.deepEqual(compactPlan.adapterUpdates, []);
  await applyWrites([compactPlan]);
  assert.equal(await readFile(path.join(root, adapter.path), 'utf8'), implementation);
  assert.equal((await planWrites(root, compact)).changes.length, 0);
  const restored = await planWrites(root, readable);
  assert.deepEqual(restored.adapterUpdates, []);
  await applyWrites([restored]);
  assert.equal((await planWrites(root, readable)).changes.length, 0);
  const manifest = JSON.parse(await readFile(path.join(root, '.lawspec/generated.json'), 'utf8'));
  assert.equal(manifest.adapters[adapter.path], digest(adapter.content));

  const changed = files({...request, minify: true, sources: [request.sources[0],
    {path: 'adapter.lawspec', content: adapterSource('Bool')} ]});
  const update = await planWrites(root, changed);
  assert.ok(update.adapterUpdates.some((a) => a.path === adapter.path));
  assert.equal(await readFile(path.join(root, adapter.path), 'utf8'), implementation);
  // Int8 and Int16 share native number representations in several targets.
  // The declared interface must remain visible despite that erasure.
  const narrow = files({...request, sources: [request.sources[0],
    {path: 'adapter.lawspec', content: adapterSource('Int8')} ]});
  const wider = files({...request, sources: [request.sources[0],
    {path: 'adapter.lawspec', content: adapterSource('Int16')} ]});
  assert.notEqual(narrow.find((a) => a.path === adapter.path).adapterReference,
    wider.find((a) => a.path === adapter.path).adapterReference);
  const generated = readable.find((a) => a.ownership === 'generated');
  await writeFile(path.join(root, generated.path), generated.content + '\n');
  await assert.rejects(planWrites(root, compact), /edited generated file/);
  console.log(`${target}: formatting, canonical adapters, legacy manifests, signature updates and edit protection pass`);
}
console.log(`Formatting fixtures: ${temporary}`);

// Exercise the real CLI/parser/examples modules against the native compiler.
// Toolchain discovery is replaced here; native integration suites test it.
const packageRoot = path.join(temporary, 'cli');
await mkdir(path.join(packageRoot, 'bin'), {recursive: true});
await mkdir(path.join(packageRoot, 'examples/specs'), {recursive: true});
for (const name of ['bin/lawspec.mjs', 'templates.mjs', 'scalars.mjs', 'files.mjs', 'examples-command.mjs']) {
  await writeFile(path.join(packageRoot, name),
    await readFile(new URL(`../npm/${name}`, import.meta.url), 'utf8'));
}
await writeFile(path.join(packageRoot, 'examples/specs/definitions.lawspec'), definitions);
await writeFile(path.join(packageRoot, 'api.mjs'), `
import {execFileSync} from 'node:child_process';
export async function createCompiler() {
  const call = (method, input) => JSON.parse(execFileSync(process.env.LAWSPEC_CORE, [], {
    input: JSON.stringify({...input, method}), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
  }));
  return Object.fromEntries(['check', 'expand', 'planGeneration'].map(method =>
    [method, input => call(method, input)]));
}
`);
await writeFile(path.join(packageRoot, 'doctor.mjs'),
  'export async function doctor(target) { return {ok: true, target: target.language}; }\n');
const run = (cwd, args) => JSON.parse(execFileSync(process.execPath,
  [path.join(packageRoot, 'bin/lawspec.mjs'), ...args, '--json'], {
    cwd, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
  }));
const project = path.join(temporary, 'project');
await mkdir(project);
await writeFile(path.join(project, 'definitions.lawspec'), definitions);
await writeFile(path.join(project, 'lawspec.json'), JSON.stringify({
  version: 1, sources: ['definitions.lawspec'],
  targets: [{language: 'javascript', root: '.', sourceDir: 'generated', testDir: 'generated'}],
}));
run(project, ['generate']);
const changed = run(project, ['generate', '--minify', '--dry-run']);
assert.ok(changed[0].changes.length > 0);
assert.deepEqual(changed[0].adapterUpdates, []);
run(project, ['generate', '--minify']);
assert.equal(run(project, ['generate', '--minify', '--check'])[0].changes.length, 0);
assert.ok(run(project, ['generate', '--dry-run'])[0].changes.length > 0);
const examples = run(project, ['examples', '--target', 'javascript', '--output', 'examples']);
assert.ok(examples[0].changes > 0);
const compactExamples = run(project, ['examples', '--target', 'javascript', '--output', 'examples', '--minify']);
assert.ok(compactExamples[0].changes > 0);
assert.deepEqual(compactExamples[0].adapterUpdates, []);
assert.equal(run(project, ['examples', '--target', 'javascript', '--output', 'examples', '--minify'])[0].changes, 0);
console.log('CLI generate/dry-run/check and examples preserve explicit formatting mode');
