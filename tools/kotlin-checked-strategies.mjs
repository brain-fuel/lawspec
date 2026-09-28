import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const base = path.join(root, '.artifacts/kotlin-checked-strategies');
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
const source = await readFile(path.join(root, 'runtime/LawSpecKotlinStrategies.kt'), 'utf8');
for (const [label, content] of [
  ['correct', source],
  ['accept-all', source.replace('schema.check(type, value, bits, symbols) is LawSpecSchema.Accepted', 'true')],
  ['reset-context', source.replace('schema.check(type, value, bits, symbols)', 'schema.check(type, value, bits, mutableMapOf())')],
  ['nested-witness', source.replace('schema.isScalar(type) -> Unit', 'true -> Unit')],
  ['hide-error', source.replace('// Keep evaluator errors for the outer checked result to report.\n                        true',
    '// Incorrectly reject evaluator errors.\n                        false')],
]) {
  if (label !== 'correct') assert.notEqual(content, source, label);
  const directory = path.join(base, label);
  await mkdir(directory, {recursive: true});
  const strategy = path.join(directory, 'LawSpecKotlinStrategies.kt');
  await writeFile(strategy, content);
  execFileSync('javac', ['--release', '25', '-d', directory,
    path.join(root, 'runtime/LawSpecRuntime.java'), path.join(root, 'runtime/LawSpecSchema.java')]);
  const classpath = [directory, dependencies].join(path.delimiter);
  const jar = path.join(directory, 'checks.jar');
  execFileSync('kotlinc', ['-jvm-target', '25', '-classpath', classpath,
    path.join(root, 'runtime/LawSpecStrategies.kt'), strategy,
    path.join(root, 'test/runtime/KotlinCheckedStrategiesCheck.kt'), '-d', jar], {encoding: 'utf8'});
  for (const bits of [32,64]) {
    const result = spawnSync('kotlin', ['-classpath', [jar, classpath].join(path.delimiter),
      'KotlinCheckedStrategiesCheckKt', String(bits)], {encoding: 'utf8', timeout: 60000});
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(base, `${label}-${bits}.log`), log);
    assert.equal(result.signal, null, log);
    if (label === 'correct') assert.equal(result.status, 0, log);
    else {
      assert.notEqual(result.status, 0, `${label} survived`);
      assert.match(log, /IllegalStateException|IllegalArgumentException|field refinement/);
      assert.doesNotMatch(log, /NoClassDefFoundError|ClassNotFoundException/);
    }
  }
}
console.log('Kotlin checked strategies pass both profiles; eight mutants detected.');
