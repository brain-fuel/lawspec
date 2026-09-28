import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_JAVA_CONSTRUCTOR_FIXTURE;
const formatter = process.env.LAWSPEC_GOOGLE_JAVA_FORMAT;
assert.ok(fixture && formatter, 'Set LAWSPEC_JAVA_CONSTRUCTOR_FIXTURE and LAWSPEC_GOOGLE_JAVA_FORMAT');
const base = path.join(root, '.artifacts/java-constructor-fields');
await mkdir(base, {recursive: true});
const source = path.join(base, 'fields.lawspec');
await writeFile(source, await readFile(path.join(root, 'test/fixtures/python_constructor_fields.lawspec'), 'utf8') + `
type HasValue (a :: Type) is HasValue item :: (m :: Maybe a where
  match m with | Nothing -> false | Just v -> true end) end
type Nested is Nested values :: List (List (n :: Int8 where n > 0)) end
`);
execFileSync(fixture, [source, base]);
for (const bits of [32, 64]) for (const mode of ['pretty', 'compact']) {
  const directory = path.join(base, String(bits), mode);
  const schemaPath = path.join(directory, 'LawSpecDataSchema.java');
  const schema = await readFile(schemaPath, 'utf8');
  const formatted = execFileSync('java', ['-jar', formatter, schemaPath], {encoding: 'utf8'});
  await writeFile(path.join(directory, 'schema.formatted.java'), formatted);
  if (mode === 'pretty') assert.equal(schema, formatted, 'Google Java Format');
  else assert.equal(formatted, await readFile(path.join(base, String(bits), 'pretty/LawSpecDataSchema.java'), 'utf8'), 'Compact syntax parity');
  const classes = path.join(directory, 'classes');
  await mkdir(classes, {recursive: true});
  const compile = () => execFileSync('javac', ['--release', '25', '-d', classes,
    path.join(directory, 'LawSpecRuntime.java'), path.join(directory, 'LawSpecSchema.java'), schemaPath,
    path.join(root, 'test/runtime/JavaGeneratedConstructorCheck.java')]);
  const run = async label => {
    compile();
    const result = spawnSync('java', ['-cp', classes, 'JavaGeneratedConstructorCheck', String(bits)], {encoding: 'utf8'});
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(directory, `${label}.log`), log);
    return {...result, log};
  };
  const correct = await run('correct');
  assert.equal(correct.status, 0, correct.log);
  for (const [label, from, to] of [
    ['symbol-reset', 'LawSpecRuntime.symbol("fixture", "same", symbols)',
      'LawSpecRuntime.symbol("fixture", "same", new java.util.HashMap<>())'],
    ['accept-all', 'return LawSpecRuntime.truth(', 'return true || LawSpecRuntime.truth('],
  ]) {
    const mutant = schema.replaceAll(from, to);
    assert.notEqual(mutant, schema);
    try {
      await writeFile(schemaPath, mutant);
      const result = await run(label);
      assert.notEqual(result.status, 0);
      assert.match(result.log, /field refinement|AssertionError/);
    } finally {
      await writeFile(schemaPath, schema);
    }
  }
  console.log(`Generated Java callbacks and two mutants passed: ${bits} ${mode}`);
}
