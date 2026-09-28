import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const directory = path.join(root, '.artifacts/java-constructor-runtime');
const formatter = process.env.LAWSPEC_GOOGLE_JAVA_FORMAT;
assert.ok(formatter, 'Set LAWSPEC_GOOGLE_JAVA_FORMAT');
await mkdir(directory, {recursive: true});
const schema = await readFile(path.join(root, 'runtime/LawSpecSchema.java'), 'utf8');
const check = path.join(root, 'test/runtime/JavaConstructorContractsCheck.java');
for (const file of [path.join(root, 'runtime/LawSpecSchema.java'), check]) {
  assert.equal(await readFile(file, 'utf8'), execFileSync('java', ['-jar', formatter, file], {encoding: 'utf8'}));
}
for (const [label, content] of [
  ['correct', schema],
  ['accept-all', schema.replace('if (!accepted)', 'if (false && !accepted)')],
  ['nested-context', schema.replace('return validate(type, value, bits, symbols);',
    'return validate(type, value, bits, new HashMap<>());')],
  ['hidden-error', schema.replace('catch (RefinementViolation rejected)',
    'catch (IllegalArgumentException rejected)')],
]) {
  if (label !== 'correct') assert.notEqual(content, schema, `mutant applied: ${label}`);
  const destination = path.join(directory, label);
  await mkdir(destination, {recursive: true});
  const source = path.join(destination, 'LawSpecSchema.java');
  await writeFile(source, content);
  execFileSync('javac', ['--release', '25', '-d', destination,
    path.join(root, 'runtime/LawSpecRuntime.java'), source, check]);
  for (const bits of [32, 64]) {
    const result = spawnSync('java', ['-cp', destination, 'JavaConstructorContractsCheck', String(bits)], {
      encoding: 'utf8', maxBuffer: 1024 * 1024,
    });
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(directory, `${label}-${bits}.log`), log);
    if (label === 'correct') assert.equal(result.status, 0, log);
    else {
      assert.notEqual(result.status, 0, `${label} survived`);
      assert.match(log, /AssertionError|field refinement/);
      assert.doesNotMatch(log, /ClassNotFoundException|NoClassDefFoundError/);
    }
  }
}
console.log('Java constructor validation and context-aware codecs pass both profiles; six mutants detected.');
