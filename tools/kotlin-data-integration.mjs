import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_KOTLIN_DATA_FIXTURE;
assert.ok(fixture, 'Set LAWSPEC_KOTLIN_DATA_FIXTURE');
const directory = path.join(root, '.artifacts/kotlin-native-data');
execFileSync(fixture, [directory]);
const cache = path.join(process.env.HOME, '.gradle/caches/modules-2/files-2.1');
async function jars(directory) {
  const entries = await readdir(directory, {withFileTypes: true});
  const files = await Promise.all(entries.map(entry => entry.isDirectory()
    ? jars(path.join(directory, entry.name)) : [path.join(directory, entry.name)]));
  return files.flat().filter(file => file.endsWith('.jar') && !file.endsWith('-sources.jar'));
}
const dependencies = [
  ...await jars(path.join(cache, 'io.kotest')),
  ...await jars(path.join(cache, 'org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm/1.8.0')),
].join(':');
for (const mode of ['pretty', 'compact']) {
  const project = path.join(directory, mode);
  const classes = path.join(project, 'classes');
  await mkdir(classes, {recursive: true});
  const javaDirectory = path.join(project, 'src/main/java/lawspec/runtime');
  const java = (await readdir(javaDirectory)).map(file => path.join(javaDirectory, file));
  execFileSync('javac', ['--release', '25', '-d', classes,
    path.join(root, 'runtime/LawSpecRuntime.java'), ...java], {stdio: 'inherit'});
  const native = path.join(project, 'src/main/kotlin/lawspec/data');
  const kotlin = (await readdir(native)).map(file => path.join(native, file));
  const support = path.join(project, 'src/main/kotlin/lawspec/runtime');
  kotlin.push(...(await readdir(support)).map(file => path.join(support, file)),
    path.join(root, 'runtime/LawSpecStrategies.kt'),
    path.join(root, 'runtime/LawSpecKotlinStrategies.kt'));
  const classpath = `${classes}:${dependencies}`;
  execFileSync('kotlinc', ['-jvm-target', '25', '-classpath', classpath, ...kotlin,
    path.join(root, 'test/runtime/KotlinDataCheck.kt'),
    path.join(root, 'test/runtime/KotlinCodecCheck.kt'),
    path.join(root, 'test/runtime/KotlinStrategiesCheck.kt'), '-d', path.join(project, 'checks.jar')],
    {stdio: 'inherit'});
  execFileSync('kotlin', ['-classpath', `${classpath}:${path.join(project, 'checks.jar')}`,
    'KotlinDataCheckKt'], {stdio: 'inherit'});
  for (const source of [
    'val bad: Tree<Boolean> = Tree.LeafCase(1.toByte())',
    'val bad: Phantom<Boolean> = Phantom.TagCase<Byte>()',
    'val bad: Empty<Boolean> = Empty<Boolean>()',
    'val bad: Tree<Byte> = Tree.BranchCase(listOf(Tree.LeafCase(true)))',
    'val schema = lawspec.runtime.LawSpecDataSchema.create()\n' +
      'val bad = lawspec.runtime.LawSpecDataCodecs.treeCodec(schema, 64, ' +
      'schema.scalar("Bool", 64, Boolean::class.javaObjectType)).encode(Tree.LeafCase(1.toByte()))',
  ]) {
    const invalid = path.join(project, 'Invalid.kt');
    await writeFile(invalid, `import lawspec.data.*\n${source}\n`);
    const result = spawnSync('kotlinc', ['-jvm-target', '25', '-classpath',
      `${classpath}:${path.join(project, 'checks.jar')}`, invalid, '-d', path.join(project, 'invalid.jar')],
      {encoding: 'utf8'});
    assert.notEqual(result.status, 0, source);
    assert.match(result.stderr, /mismatch|cannot access|private/i);
  }
  console.log(`Kotlin rejected invalid native payloads: ${mode}`);
}
