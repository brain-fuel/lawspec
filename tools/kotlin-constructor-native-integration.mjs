import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {access, mkdir, readFile, readdir, realpath, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_KOTLIN_CONSTRUCTOR_FIXTURE;
const formatter = process.env.LAWSPEC_GOOGLE_JAVA_FORMAT;
assert.ok(fixture && formatter, 'Set LAWSPEC_KOTLIN_CONSTRUCTOR_FIXTURE and LAWSPEC_GOOGLE_JAVA_FORMAT');
const base = path.join(root, '.artifacts/kotlin-constructor-native');
await mkdir(base, {recursive: true});
const input = path.join(base, 'fields.lawspec');
await writeFile(input, (await readFile(path.join(root, 'test/fixtures/python_constructor_fields.lawspec'), 'utf8'))
  .replace('unit native.fields', 'unit fixture.fields') + `
definition echoList (values :: List (Maybe Identity)) :: List (Maybe Identity) is values end
definition echoIdentityBucket (box :: Bucket Identity) :: Bucket Identity is box end
definition echoNested (value :: Optional (Nullable Identity)) :: Optional (Nullable Identity) is value end
definition echoNullable (value :: Nullable Identity) :: Nullable Identity is value end
definition echoOptional (value :: Optional Identity) :: Optional Identity is value end
type Raw is Raw value :: (c :: CodeUnit16 where c == codeUnit16(55296)) end
definition echoRaw (value :: Raw) :: Raw is value end
`);
execFileSync(fixture, [input, base]);
let home = process.env.LAWSPEC_KOTLIN_HOME ?? path.dirname(path.dirname(
  await realpath(execFileSync('which', ['kotlinc'], {encoding: 'utf8'}).trim())));
if (!await access(path.join(home, 'lib/kotlin-compiler.jar')).then(() => true, () => false))
  home = path.join(home, 'libexec');
const checker = path.join(base, 'checker');
await mkdir(checker, {recursive: true});
execFileSync('javac', ['-cp', path.join(home, 'lib/*'), '-d', checker,
  path.join(root, 'tools/KotlinFormatCheck.java')]);
const rows = [];
for (const bits of [32,64]) for (const mode of ['pretty','compact']) {
  const directory = path.join(base, String(bits), mode);
  const names = await readdir(path.join(directory, 'src/main'), {recursive: true});
  const java = names.filter(name => name.endsWith('.java')).map(name => path.join(directory, 'src/main', name));
  const kotlin = names.filter(name => name.endsWith('.kt')).map(name => path.join(directory, 'src/main', name));
  for (const file of java) {
    const formatted = execFileSync('java', ['-jar', formatter, file], {encoding: 'utf8', maxBuffer: 16 * 1024 * 1024});
    if (mode === 'pretty') assert.equal(await readFile(file, 'utf8'), formatted, file);
    else assert.equal(formatted, await readFile(file.replace('/compact/', '/pretty/'), 'utf8'));
  }
  if (mode === 'pretty') for (const file of kotlin) rows.push([
    file, file.replace('/pretty/', '/compact/'), file,
  ].join('\t'));
  const classes = path.join(directory, 'classes');
  await mkdir(classes, {recursive: true});
  execFileSync('javac', ['--release', '25', '-d', classes, ...java]);
  const jar = path.join(directory, 'native.jar');
  const run = async label => {
    execFileSync('kotlinc', ['-jvm-target', '25', '-classpath', classes, ...kotlin,
      path.join(root, 'test/runtime/KotlinNativeConstructorCheck.kt'), '-d', jar], {encoding: 'utf8', maxBuffer: 8 * 1024 * 1024});
    const result = spawnSync('kotlin', ['-classpath', [jar, classes].join(path.delimiter),
      'KotlinNativeConstructorCheckKt', String(bits)], {encoding: 'utf8'});
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(directory, `${label}.log`), log);
    return {...result, log};
  };
  const correct = await run('correct');
  assert.equal(correct.status, 0, correct.log);
  const codecs = kotlin.find(file => file.endsWith('/LawSpecDataCodecs.kt'));
  const original = await readFile(codecs, 'utf8');
  const mutant = original.replace(/(return schema\.codec<[^>]+>\(\s*type,\s*bits,\s*)symbols,/g,
    '$1mutableMapOf<String, Any>(),');
  assert.notEqual(mutant, original);
  try {
    await writeFile(codecs, mutant);
    const bad = await run('codec-context-mutant');
    assert.notEqual(bad.status, 0);
    assert.match(bad.log, /field refinement/);
  } finally {
    await writeFile(codecs, original);
  }
  console.log(`Kotlin native constructor contexts and mutant pass: ${bits} ${mode}`);
}
const manifest = path.join(base, 'format.tsv');
await writeFile(manifest, rows.join('\n') + '\n');
execFileSync('java', ['-cp', checker + path.delimiter + path.join(home, 'lib/*'),
  'KotlinFormatCheck', manifest], {stdio: 'inherit'});
