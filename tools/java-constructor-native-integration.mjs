import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, readdir, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_JAVA_CONSTRUCTOR_NATIVE_FIXTURE;
const formatter = process.env.LAWSPEC_GOOGLE_JAVA_FORMAT;
assert.ok(fixture && formatter, 'Set LAWSPEC_JAVA_CONSTRUCTOR_NATIVE_FIXTURE and LAWSPEC_GOOGLE_JAVA_FORMAT');
const base = path.join(root, '.artifacts/java-constructor-native');
await mkdir(base, {recursive: true});
const input = path.join(base, 'fields.lawspec');
const source = (await readFile(path.join(root, 'test/fixtures/python_constructor_fields.lawspec'), 'utf8'))
  .replace('unit native.fields', 'unit fixture.fields') + `
definition echoList (values :: List (Maybe Identity)) :: List (Maybe Identity) is values end
definition echoNullable (value :: Nullable Identity) :: Nullable Identity is value end
definition echoOptional (value :: Optional Identity) :: Optional Identity is value end
type Raw is Raw value :: (c :: CodeUnit16 where c == codeUnit16(55296)) end
definition echoRaw (value :: Raw) :: Raw is value end
`;
await writeFile(input, source);
execFileSync(fixture, [input, base]);
for (const bits of [32, 64]) for (const mode of ['pretty', 'compact']) {
  const directory = path.join(base, String(bits), mode);
  const sourceRoot = path.join(directory, 'src/main/java');
  const files = (await readdir(sourceRoot, {recursive: true}))
    .filter(name => name.endsWith('.java')).map(name => path.join(sourceRoot, name));
  for (const file of files) {
    const content = await readFile(file, 'utf8');
    const formatted = execFileSync('java', ['-jar', formatter, file], {encoding: 'utf8'});
    await writeFile(file + '.formatted', formatted);
    if (mode === 'pretty') assert.equal(content, formatted, file);
    else assert.equal(formatted, await readFile(file.replace('/compact/', '/pretty/'), 'utf8'), 'Compact parity');
  }
  const classes = path.join(directory, 'classes');
  await mkdir(classes, {recursive: true});
  const run = async label => {
    execFileSync('javac', ['--release', '25', '-d', classes, ...files,
      path.join(root, 'test/runtime/JavaNativeConstructorCheck.java')]);
    const result = spawnSync('java', ['-cp', classes, 'JavaNativeConstructorCheck', String(bits)], {encoding: 'utf8'});
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(directory, `${label}.log`), log);
    return {...result, log};
  };
  const correct = await run('correct');
  assert.equal(correct.status, 0, correct.log);
  const codecPath = path.join(sourceRoot, 'lawspec/runtime/LawSpecDataCodecs.java');
  const codecs = await readFile(codecPath, 'utf8');
  const mutant = codecs.replace(/(return schema\.codec\(\s*type,\s*bits,\s*)symbols,/g,
    '$1new java.util.HashMap<>(),');
  assert.notEqual(mutant, codecs);
  try {
    await writeFile(codecPath, mutant);
    const result = await run('codec-context-mutant');
    assert.notEqual(result.status, 0);
    assert.match(result.log, /field refinement/);
  } finally {
    await writeFile(codecPath, codecs);
  }
  console.log(`Java native constructor APIs, codecs, context mutant and formatting passed: ${bits} ${mode}`);
}
