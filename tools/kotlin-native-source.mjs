import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
assert.ok(process.env.LAWSPEC_CORE, 'Set LAWSPEC_CORE');
const read = name => readFile(path.join(root, name), 'utf8');
const payments = JSON.parse(await read('test/fixtures/native-payments/bindings-kotlin.json'));
const shapes = JSON.parse(await read('test/fixtures/native-shapes/bindings-kotlin.json'));
for (const machineBits of [32, 64]) {
  const directory = path.join(root, `.artifacts/kotlin-native-source/${machineBits}`);
  const result = JSON.parse(execFileSync(process.env.LAWSPEC_CORE, [], {
    input: JSON.stringify({schemaVersion: 4, method: 'planGeneration', target: 'kotlin', machineBits,
      nativeBindings: {types: [...payments.types, ...shapes.types], functions: [...payments.functions, ...shapes.functions]},
      sources: [{path: 'payments.lawspec', content: await read('examples/specs/payments.lawspec')},
        {path: 'shapes.lawspec', content: await read('test/fixtures/native_shapes.lawspec')}]}),
    encoding: 'utf8', maxBuffer: 64 * 1024 * 1024,
  }));
  assert.deepEqual(result.diagnostics, []);
  const java = [], kotlin = [];
  for (const file of result.files.filter(file => file.placement === 'source')) {
    const destination = path.join(directory, file.path);
    await mkdir(path.dirname(destination), {recursive: true});
    await writeFile(destination, file.content);
    if (file.path.endsWith('.java')) java.push(destination);
    if (file.path.endsWith('.kt')) kotlin.push(destination);
  }
  const classes = path.join(directory, 'classes');
  await mkdir(classes, {recursive: true});
  execFileSync('javac', ['--release', '25', '-d', classes, ...java], {stdio: 'inherit'});
  const jar = path.join(directory, 'source.jar');
  // Only source files and the Kotlin standard library: no Kotest dependencies.
  execFileSync('kotlinc', ['-jvm-target', '25', '-classpath', classes, ...kotlin,
    path.join(root, 'test/fixtures/native-payments/PaymentsDomain.kt'),
    path.join(root, 'test/fixtures/native-shapes/Shapes.kt'),
    path.join(root, 'test/runtime/KotlinNativeBindingsCheck.kt'), '-d', jar], {stdio: 'inherit'});
  execFileSync('kotlin', ['-classpath', `${jar}:${classes}`, 'domain.KotlinNativeBindingsCheckKt', `${machineBits}`], {stdio: 'inherit'});
}
