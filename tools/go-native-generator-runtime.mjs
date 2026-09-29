import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const directory = path.join(root, '.artifacts/go-native-generators');
await mkdir(directory, {recursive: true});
const env = {...process.env, GOCACHE: path.join(root, '.artifacts/go-cache'),
  GOTOOLCHAIN: 'local', GOPROXY: 'off'};
const rapid = path.join(execFileSync('go', ['env', 'GOMODCACHE'], {encoding: 'utf8'}).trim(),
  'pgregory.net/rapid@v1.2.0');
await writeFile(path.join(directory, 'go.mod'),
  'module fixture\n\ngo 1.24.0\n\nrequire pgregory.net/rapid v1.2.0\nreplace pgregory.net/rapid => ' +
  JSON.stringify(rapid) + '\n');
for (const name of ['lawspec_runtime.go', 'lawspec_schema.go', 'lawspec_codecs.go', 'lawspec_data_strategies.go']) {
  const source = (await readFile(path.join(root, 'runtime', name), 'utf8'))
    .replace('package RUNTIME_PACKAGE', 'package fixture');
  assert.equal(execFileSync('gofmt', [], {input: source, encoding: 'utf8'}), source);
  await writeFile(path.join(directory, name), source);
}
await writeFile(path.join(directory, 'checked_test.go'),
  await readFile(path.join(root, 'test/runtime/GoCheckedStrategiesCheck.go'), 'utf8'));
await writeFile(path.join(directory,'native_test.go'),await readFile(path.join(root,'test/runtime/GoNativeGeneratorsCheck.go'),'utf8'));
execFileSync('go',['test','./...','-count=1','-rapid.seed=424242','-rapid.nofailfile'],{cwd:directory,env,stdio:'inherit'});
for (const [name, variable, expected] of [
  ['TestNativeShrink','LAWSPEC_NATIVE_SHRINK',/minimal_native=61/],
  ['TestNativeInvalidShrink','LAWSPEC_NATIVE_INVALID_SHRINK',/observed_invalid_shrink=.*native generator Int8/],
  ['TestNativeExhausted','LAWSPEC_NATIVE_EMPTY',/only generated 0 valid tests/],
  ['TestNativePhantomEmpty','LAWSPEC_NATIVE_PHANTOM_EMPTY',/only generated 0 valid tests/],
  ['TestNativePhantomEmpty','LAWSPEC_NATIVE_PHANTOM_SHRINK',/minimal_phantom=61/],
]) {
  const result=spawnSync('go',['test','-count=1','-run',`^${name}$`,'-rapid.seed=424242','-rapid.nofailfile'],
    {cwd:directory,env:{...env,[variable]:'1'},encoding:'utf8',timeout:60000});
  const log=result.stdout+result.stderr;
  await writeFile(path.join(directory,`${name}-${variable}.log`),log);
  assert.equal(result.error,undefined,log);
  assert.notEqual(result.status,0);
  assert.match(log,expected);
  assert.match(log,/--- FAIL:/);
  console.log(`${name}: expected native failure verified`);
}
