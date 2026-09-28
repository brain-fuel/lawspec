// Verify emitted strings and contextual failures with Java's own compiler/runtime.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {mkdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {templates} from '../npm/templates.mjs';
const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
assert.ok(compiler, 'Set LAWSPEC_CORE');
const label = 'a descriptive diagnostic with apostrophes \' and quotes " and backslashes \\ plus supplementary Unicode 🙂 preserved exactly';
const payload = 'fixture: repeated spaces   quotes " backslashes \\ and supplementary Unicode 🙂 must arrive unchanged ' + '🙂'.repeat(40);
const integers = [-(2n ** 127n) - 1n, -(2n ** 127n), 2n ** 127n - 1n, 2n ** 127n, -(2n ** 256n), 2n ** 256n];
const source = `unit diagnostic
echo :: Text -> Text
parseInteger :: Text -> BigInt
law \`${label}\` is
  definition is \`for all\` (x :: Text) . echo x = x end
  example \`literal\` is x = ${JSON.stringify(payload)} expect echo x = ${JSON.stringify(payload)} end
end
${integers.map((value, i) => `law \`integer representation ${i}\` is
definition is \`for all\` (marker :: Unit) . parseInteger "${value}" = ${value} end end`).join('\n')}`;
// Expected strings bypass the compiler's Java quoting/chunking implementation.
const nativeString = value => `new String(java.util.Base64.getDecoder().decode("${Buffer.from(value, 'utf8').toString('base64')}"), java.nio.charset.StandardCharsets.UTF_8)`;
for (const minify of [false, true]) {
  const directory = path.join(root, '.artifacts/java-messages', minify ? 'compact' : 'readable');
  const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
    method: 'planGeneration', target: 'java', minify, sources: [{path: 'diagnostic', content: source}],
  }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
  assert.deepEqual(result.diagnostics, []);
  for (const file of [...Object.entries(templates('java', {minify})).map(([path, content]) => ({path, content})), ...result.files]) {
    const destination = path.join(directory, file.path);
    await mkdir(path.dirname(destination), {recursive: true});
    await writeFile(destination, file.content);
  }
  const adapter = result.files.find(file => file.ownership === 'user');
  const adapterPath = path.join(directory, adapter.path);
  const nativeAdapter = `public class Diagnostic {
    public static String echo(String value) {
      if (value.startsWith("fixture:") && !value.equals(${nativeString(payload)})) throw new AssertionError("changed literal");
      return value;
    }
    public static java.math.BigInteger parseInteger(String value) { return new java.math.BigInteger(value); }
  }`;
  await writeFile(adapterPath, nativeAdapter);
  const checkPath = path.join(directory, 'src/test/java/DiagnosticPayloadTest.java');
  // An inert class keeps regeneration/repeated runs from retaining the failure probe.
  await writeFile(checkPath, 'class DiagnosticPayloadTest {}\n');
  const run = args => execFileSync('mvn', ['-o', '-q', 'test', ...args], {cwd: directory, stdio: 'inherit'});
  run([]);
  const expected = `diagnostic::${label} boundary 0 | expect echo (_input0) = _input0`;
  await writeFile(checkPath, `class DiagnosticPayloadTest {
    @org.junit.jupiter.api.Test void context() {
      var error = org.junit.jupiter.api.Assertions.assertThrows(AssertionError.class, () -> new DiagnosticLawSpecTest().law0Boundary0());
      org.junit.jupiter.api.Assertions.assertTrue(error.getMessage().startsWith(${nativeString(expected)}), error.getMessage());
    }
  }`);
  await writeFile(adapterPath, nativeAdapter.replace('return value;', 'return value + "broken";'));
  try { run(['-Dtest=DiagnosticPayloadTest']); }
  finally {
    await writeFile(adapterPath, nativeAdapter);
    await writeFile(checkPath, 'class DiagnosticPayloadTest {}\n');
  }
  console.log(`Java ${minify ? 'compact' : 'readable'}: exact literals and diagnostic text preserved`);
}
