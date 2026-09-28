import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const formatter = process.env.LAWSPEC_GOOGLE_JAVA_FORMAT;
const jetcheck = process.env.LAWSPEC_JETCHECK;
assert.ok(formatter && jetcheck, 'Set LAWSPEC_GOOGLE_JAVA_FORMAT and LAWSPEC_JETCHECK');
const directory = path.join(root, '.artifacts/java-checked-strategies');
const runtimePath = path.join(root, 'runtime/LawSpecDataStrategies.java');
const test = path.join(root, 'test/runtime/JavaCheckedStrategiesCheck.java');
const source = await readFile(runtimePath, 'utf8');
for (const file of [runtimePath, test]) {
  assert.equal(await readFile(file, 'utf8'), execFileSync('java', ['-jar', formatter, file], {encoding: 'utf8'}));
}
for (const [label, content] of [
  ['correct', source],
  ['accept-all', source.replaceAll('schema.check(type, value, bits, symbols)', '((LawSpecSchema.ValueCheck) new LawSpecSchema.Accepted(value))')],
  ['reset-context', source.replace('schema.check(type, value, bits, symbols)', 'schema.check(type, value, bits, new HashMap<>())')],
  ['nested-witness', source.replace('if (schema.isScalar(type)) return;', 'if (true) return;')],
  ['hide-error', source.replace('return new Checked(null, error);', 'return new Checked(null, null);')],
]) {
  if (label !== 'correct') assert.notEqual(content, source);
  const destination = path.join(directory, label);
  await mkdir(destination, {recursive: true});
  const file = path.join(destination, 'LawSpecDataStrategies.java');
  await writeFile(file, content);
  execFileSync('javac', ['--release', '25', '-cp', jetcheck, '-d', destination,
    path.join(root, 'runtime/LawSpecRuntime.java'), path.join(root, 'runtime/LawSpecSchema.java'), file, test]);
  for (const bits of [32, 64]) {
    const result = spawnSync('java', ['-cp', [destination, jetcheck].join(path.delimiter),
      'JavaCheckedStrategiesCheck', String(bits)], {encoding: 'utf8', timeout: 60000});
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(directory, `${label}-${bits}.log`), log);
    assert.equal(result.signal, null, log);
    if (label === 'correct') assert.equal(result.status, 0, log);
    else {
      assert.notEqual(result.status, 0, `${label} survived`);
      assert.match(log, /AssertionError|PropertyFalsified|CannotSatisfyCondition/);
      assert.doesNotMatch(log, /ClassNotFoundException|NoClassDefFoundError/);
    }
  }
}
console.log('Java checked strategies pass both profiles; eight behavioral mutants detected.');
