import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir, readFile, readdir} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const directory = path.join(root, '.artifacts/java-native-data');
const fixture = process.env.LAWSPEC_JAVA_DATA_FIXTURE;
const formatter = process.env.LAWSPEC_GOOGLE_JAVA_FORMAT;
assert.ok(fixture, 'Set LAWSPEC_JAVA_DATA_FIXTURE to the freshly compiled java-data-fixture');
assert.ok(formatter, 'Set LAWSPEC_GOOGLE_JAVA_FORMAT');
execFileSync(fixture, [directory]);
for (const mode of ['pretty', 'compact']) {
  const source = path.join(directory, mode, 'src/main/java/lawspec/data');
  const runtimeSource = path.join(directory, mode, 'src/main/java/lawspec/runtime');
  const files = [...(await readdir(source)).map(name => path.join(source, name)),
    ...(await readdir(runtimeSource)).map(name => path.join(runtimeSource, name))];
  if (mode === 'pretty') {
    for (const file of files) {
      assert.equal(await readFile(file, 'utf8'),
        execFileSync('java', ['-jar', formatter, file], {encoding: 'utf8'}),
        `Google Java Format: ${path.basename(file)}`);
    }
  }
  const classes = path.join(directory, mode, 'classes');
  await mkdir(classes, {recursive: true});
  execFileSync('javac', ['--release', '25', '-d', classes,
    path.join(root, 'runtime/LawSpecRuntime.java'), ...files,
    path.join(root, 'test/runtime/NativeDataCheck.java'),
    path.join(root, 'test/runtime/DataSchemaCheck.java')], {stdio: 'inherit'});
  execFileSync('java', ['-cp', classes, 'NativeDataCheck'], {stdio: 'inherit'});
  for (const bits of [32, 64]) {
    execFileSync('java', ['-cp', classes, 'DataSchemaCheck', String(bits)], {stdio: 'inherit'});
  }
}
