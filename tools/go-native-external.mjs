import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile, unlink} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
assert.ok(compiler, 'Set LAWSPEC_CORE');
const {createCompiler} = await import('../npm/api.mjs');
const wasm = await createCompiler();
const read = name => readFile(path.join(root, 'test/fixtures/native-go-external', name), 'utf8');
const bindings = JSON.parse(await read('bindings.json'));
const content = await read('domain.lawspec');
const domain = await read('domain.go');
const rapid = path.join(execFileSync('go', ['env', 'GOMODCACHE'], {encoding: 'utf8'}).trim(), 'pgregory.net/rapid@v1.2.0');
const env = {...process.env, GOCACHE: path.join(root, '.artifacts/go-cache'), GOTOOLCHAIN: 'local', GOPROXY: 'off'};
for (const machineBits of [32, 64]) for (const minify of [false, true]) {
  const directory = path.join(root, `.artifacts/go-native-external/${machineBits}-${minify}`);
  const sourceDir = machineBits === 32 ? 'library/native' : 'src';
  const request = {schemaVersion:4, method:'planGeneration', target:'go', machineBits, minify,
    sourceDir, testDir:sourceDir, nativeBindings:bindings, generation:{exhaustiveLimit:1},
    sources:[{path:'external.lawspec',content}]};
  const result = JSON.parse(execFileSync(compiler, [], {input:JSON.stringify(request), encoding:'utf8', maxBuffer:64*1024*1024}));
  assert.deepEqual(result.diagnostics, []);
  assert.deepEqual(await wasm.planGeneration(request), result, 'Go external native/WASM parity');
  for (const file of result.files) {
    const destination = path.join(directory,file.path);
    await mkdir(path.dirname(destination),{recursive:true});
    await writeFile(destination,file.content);
    assert.ok(!file.content.includes('example.invalid/not-imported'));
  }
  for (const name of ['domain','generators']) await mkdir(path.join(directory,name),{recursive:true});
  await writeFile(path.join(directory,'domain/domain.go'),domain);
  await writeFile(path.join(directory,'generators/generators.go'),await read('generators.go'));
  await writeFile(path.join(directory,'go.mod'),`module example.invalid/native\n\ngo 1.23\n\nrequire pgregory.net/rapid v1.2.0\nreplace pgregory.net/rapid => ${rapid}\n`);
  const options = {cwd:directory, env, encoding:'utf8', maxBuffer:32*1024*1024};
  execFileSync('go',['build','./domain',`./${sourceDir}/...`],options);
  const resultTest = spawnSync('go',['test','-count=1','./...'],options);
  await writeFile(path.join(directory,'correct.log'),resultTest.stdout+resultTest.stderr);
  assert.equal(resultTest.status,0,resultTest.stdout+resultTest.stderr);
  assert.ok(domain.includes('func CopyBox(value Box[int8]) Box[int8] { return value }'));
  await writeFile(path.join(directory,'domain/domain.go'),domain.replace('func CopyBox(value Box[int8]) Box[int8] { return value }',
    'func CopyBox(value Box[int8]) Box[int8] { return Box[int8]{} }'));
  execFileSync('go',['build',`./${sourceDir}/...`],options);
  const failed = spawnSync('go',['test','-count=1','./...'],options);
  await writeFile(path.join(directory,'wrong-adapter.log'),failed.stdout+failed.stderr);
  assert.notEqual(failed.status,0);
  assert.match(failed.stdout+failed.stderr,/FAIL/);
  await writeFile(path.join(directory,'domain/domain.go'),domain);
  const shrinkPath = path.join(directory, sourceDir, 'external/binding/external_shrink_test.go');
  await writeFile(shrinkPath, (await read('shrink_test.go')).replace('bits := 64', `bits := ${machineBits}`));
  const shrunk = spawnSync('go', ['test', '-count=1', '-run', '^TestExternalShrinking$', `./${sourceDir}/external/binding`], options);
  await writeFile(path.join(directory, 'external-shrinking.log'), shrunk.stdout + shrunk.stderr);
  try {
    assert.notEqual(shrunk.status, 0);
    assert.match(shrunk.stdout + shrunk.stderr, /payload 61/);
  } finally {
    await unlink(shrinkPath);
  }
  console.log(`Go external types, functions and generic Rapid factory passed: ${machineBits}, compact=${minify}`);
}
