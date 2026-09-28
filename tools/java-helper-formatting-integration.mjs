// Check helper members independently while property scaffolding is migrated.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFile, writeFile, mkdir} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const formatter = process.env.LAWSPEC_GOOGLE_JAVA_FORMAT;
assert.ok(compiler && formatter, 'Set LAWSPEC_CORE and LAWSPEC_GOOGLE_JAVA_FORMAT');
const source = await readFile(path.join(root, 'test/fixtures/total_definitions.lawspec'), 'utf8');
for (const machineBits of [32, 64]) {
  const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target: 'java', machineBits,
    sources: [{path: 'total.lawspec', content: source}],
  }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
  assert.deepEqual(result.diagnostics, []);
  const file = result.files.find(file => file.path.endsWith('/TotalLawSpecTest.java'));
  assert.ok(file);
  const start = file.content.indexOf('  private record _LawSpecInputs');
  const end = file.content.indexOf('  private static Value _lawspec_call_', start);
  assert.ok(start >= 0 && end > start, 'Missing helper region');
  const snippet = `class Helpers {\n${file.content.slice(start, end).trimEnd()}\n}\n`;
  const formatted = execFileSync('java', ['-jar', formatter, '-'], {
    input: snippet, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
  });
  const directory = path.join(root, '.artifacts/java-helper-formatting', String(machineBits));
  await mkdir(directory, {recursive: true});
  await writeFile(path.join(directory, 'Helpers.generated.java'), snippet);
  await writeFile(path.join(directory, 'Helpers.formatted.java'), formatted);
  assert.equal(snippet, formatted, `Google Java Format differs: ${directory}`);
  console.log(`Java primitive registry and assertion helpers match Google Java Format: ${machineBits}`);
}
