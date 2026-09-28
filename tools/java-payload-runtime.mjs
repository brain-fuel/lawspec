import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const directory = path.join(root, '.artifacts/java-payload-runtime');
const formatter = process.env.LAWSPEC_GOOGLE_JAVA_FORMAT;
assert.ok(formatter, 'Set LAWSPEC_GOOGLE_JAVA_FORMAT');
const schema = await readFile(path.join(root, 'runtime/LawSpecSchema.java'), 'utf8');
const runtime = await readFile(path.join(root, 'runtime/LawSpecRuntime.java'), 'utf8');
const check = path.join(root, 'test/runtime/JavaPayloadCheck.java');
for (const file of [path.join(root, 'runtime/LawSpecSchema.java'), check]) {
  assert.equal(await readFile(file, 'utf8'), execFileSync('java', ['-jar', formatter, file], {encoding: 'utf8'}));
}
async function run(label, schemaSource, runtimeSource, correct) {
  const output = path.join(directory, label);
  await mkdir(output, {recursive: true});
  await writeFile(path.join(output, 'LawSpecSchema.java'), schemaSource);
  await writeFile(path.join(output, 'LawSpecRuntime.java'), runtimeSource);
  execFileSync('javac', ['--release', '25', '-d', output,
    path.join(output, 'LawSpecRuntime.java'), path.join(output, 'LawSpecSchema.java'), check]);
  for (const bits of [32, 64]) {
    const result = spawnSync('java', ['-cp', output, 'JavaPayloadCheck', String(bits)], {
      encoding: 'utf8', timeout: 30000,
    });
    const log = (result.stdout ?? '') + (result.stderr ?? '');
    await writeFile(path.join(output, `${bits}.log`), log);
    assert.equal(result.error, undefined);
    if (correct) assert.equal(result.status, 0, log);
    else {
      assert.notEqual(result.status, 0, `Payload mutant survived: ${label}`);
      assert.match(log, /AssertionError/);
    }
  }
}
await run('correct', schema, runtime, true);
for (const [label, before, after] of [
  ['parameter', 'return arguments.get(parameter.index());', 'return arguments.get(0);'],
  ['fixed', '? IgnorePayload.INSTANCE\n        : new PayloadApplication', '? new PayloadSlot(0)\n        : new PayloadApplication'],
  ['validation', 'var checked = validate(type, value, bits, symbols);\n    var arguments',
    'var checked = value;\n    var arguments'],
  ['reject', 'return LawSpecRuntime.truth(predicates.get(slot.index()).apply(value));', 'return true;'],
]) {
  assert.ok(schema.includes(before), before);
  await run(label, schema.replace(before, after), runtime, false);
}
console.log('Java payload runtime passes both widths; four compiled mutants rejected');
if (process.env.LAWSPEC_CORE) {
  const content = await readFile(path.join(root, 'examples/specs/data_types.lawspec'), 'utf8');
  for (const machineBits of [32, 64]) for (const minify of [false, true]) {
    const result = JSON.parse(execFileSync(process.env.LAWSPEC_CORE, [], {
      input: JSON.stringify({method: 'planGeneration', target: 'java', machineBits, minify,
        sources: [{path: 'data.lawspec', content}]}), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
    }));
    assert.deepEqual(result.diagnostics, []);
    const get = name => {
      const artifact = result.files.find(file => file.path.endsWith('/' + name));
      assert.ok(artifact, name);
      return artifact.content;
    };
    await run(`generated-${machineBits}-${minify}`, get('LawSpecSchema.java'),
      get('LawSpecRuntime.java'), true);
  }
  console.log('Generated Java payload runtimes compile and execute at both widths/layouts');
}
