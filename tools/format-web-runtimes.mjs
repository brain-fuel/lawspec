// Development-only formatter. Generated projects do not load or install it.
import assert from 'node:assert/strict';
import {createRequire} from 'node:module';
import {indentContinuations, continuationViolations} from './web-continuations.mjs';
import {readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL} from 'node:url';

const root = path.resolve(import.meta.dirname, '..');
const formatterPath = process.env.LAWSPEC_PRETTIER ??
  path.join(root, '.artifacts/formatter-deps/prettier/index.mjs');
const prettier = await import(pathToFileURL(formatterPath));
assert.equal(prettier.version, '3.6.2', 'Use the pinned Prettier 3.6.2');
const require = createRequire(import.meta.url);
const ts = require(process.env.LAWSPEC_TYPESCRIPT ??
  path.join(root, '.artifacts/web-data-deps/typescript/lib/typescript.js'));
const write = process.argv.slice(2).includes('--write');
assert.ok(process.argv.slice(2).every((arg) => arg === '--write'),
  'Usage: node tools/format-web-runtimes.mjs [--write]');
const options = {
  parser: 'babel', printWidth: 80, tabWidth: 2, singleQuote: true,
  bracketSpacing: false, semi: true, trailingComma: 'all', arrowParens: 'always',
};
for (const name of ['lawspec_runtime.mjs', 'lawspec_schema.mjs', 'lawspec_data_strategies.mjs']) {
  const file = path.join(root, 'runtime', name);
  const before = await readFile(file, 'utf8');
  let formatted;
  for (const printWidth of [80, 76, 72, 68, 64, 60]) {
    const base = await prettier.format(before, {...options, printWidth});
    const source = ts.createSourceFile(name, base, ts.ScriptTarget.ESNext, true, ts.ScriptKind.JS);
    assert.deepEqual(source.parseDiagnostics, []);
    formatted = indentContinuations(ts, source);
    if (formatted.split('\n').every(line => [...line].length <= 80)) break;
  }
  assert.ok(formatted.split('\n').every(line => [...line].length <= 80),
    `${name}: runtime source needs additional legal line breaks`);
  const parsed = ts.createSourceFile(name, formatted, ts.ScriptTarget.ESNext, true, ts.ScriptKind.JS);
  assert.deepEqual(parsed.parseDiagnostics, []);
  assert.deepEqual(continuationViolations(ts, parsed), []);
  if (write) await writeFile(file, formatted);
  else assert.equal(before, formatted, `${name} needs formatting`);
  console.log(`${name}: ${write ? 'formatted' : 'format verified'}`);
}
