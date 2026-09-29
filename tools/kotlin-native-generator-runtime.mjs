import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const base = path.join(root, '.artifacts/kotlin-native-generators');
async function jars(directory) {
  const entries = await readdir(directory, {withFileTypes: true});
  return (await Promise.all(entries.map(entry => entry.isDirectory()
    ? jars(path.join(directory, entry.name)) : [path.join(directory, entry.name)])))
    .flat().filter(file => file.endsWith('.jar') && !file.endsWith('-sources.jar'));
}
const cache = path.join(process.env.HOME, '.gradle/caches/modules-2/files-2.1');
const dependencies = (await Promise.all(['io.kotest',
  'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.8.0',
].map(group => jars(path.join(cache, group))))).flat().join(path.delimiter);
await mkdir(base, {recursive:true});
execFileSync('javac', ['--release', '25', '-d', base,
  path.join(root, 'runtime/LawSpecRuntime.java'), path.join(root, 'runtime/LawSpecSchema.java')]);
const classpath = [base, dependencies].join(path.delimiter);
const jar = path.join(base, 'checks.jar');
execFileSync('kotlinc', ['-jvm-target', '25', '-classpath', classpath,
  path.join(root, 'runtime/LawSpecStrategies.kt'), path.join(root, 'runtime/LawSpecKotlinStrategies.kt'),
  path.join(root, 'test/runtime/KotlinNativeGeneratorsCheck.kt'),
  path.join(root, 'test/runtime/KotlinCheckedStrategiesCheck.kt'), '-d', jar], {stdio:'inherit'});
for (const bits of [32,64]) for (const check of ['KotlinNativeGeneratorsCheckKt', 'KotlinCheckedStrategiesCheckKt']) {
  const result = spawnSync('kotlin', ['-classpath', [jar, classpath].join(path.delimiter),
    check, String(bits)], {encoding:'utf8', timeout:60000});
  const log = (result.stdout ?? '') + (result.stderr ?? '');
  await writeFile(path.join(base, `${check}-${bits}.log`), log);
  assert.equal(result.signal, null, log);
  assert.equal(result.status, 0, log);
  console.log(log.trim());
}
