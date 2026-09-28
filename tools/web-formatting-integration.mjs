// Parse generated JS/TS independently, audit style, and record formatter differences.
// Prettier is a comparison, not an exact Google-style oracle (+4 continuations).
import assert from 'node:assert/strict';
import {continuationViolations, indentContinuations} from './web-continuations.mjs';
import {execFileSync} from 'node:child_process';
import {mkdir, readFile, readdir, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {createRequire} from 'node:module';
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';

const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
assert.ok(compiler, 'Set LAWSPEC_CORE');
const formatter = process.env.LAWSPEC_PRETTIER ??
  path.join(root, '.artifacts/formatter-deps/prettier/index.mjs');
const prettier = await import(pathToFileURL(formatter));
assert.equal(prettier.version, '3.6.2');
const specs = process.argv.slice(2).length ? process.argv.slice(2) : [
  'test/fixtures/total_definitions.lawspec',
  ...(await readdir(path.join(root, 'examples/specs'))).filter(name => name.endsWith('.lawspec'))
    .sort().map(name => `examples/specs/${name}`),
];
const require = createRequire(import.meta.url);
const ts = require(process.env.LAWSPEC_TYPESCRIPT ??
  path.join(root, '.artifacts/web-data-deps/typescript/lib/typescript.js'));
const mismatches = [];
const violations = [];
function audit(file, target, readable) {
  const parsed = ts.createSourceFile(file.path, file.content, ts.ScriptTarget.ESNext,
    true, target === 'typescript' ? ts.ScriptKind.TS : ts.ScriptKind.JS);
  assert.deepEqual(parsed.parseDiagnostics, [], file.path);
  const hash = createHash('sha256');
  const messages = readable ? continuationViolations(ts, parsed) : [];
  const columnExceptions = new Set();
  const line = position => parsed.getLineAndCharacterOfPosition(position).line;
  const visit = node => {
    if (ts.isImportDeclaration(node) ||
        (ts.isExportDeclaration(node) && node.moduleSpecifier)) {
      for (let index = line(node.getStart(parsed)); index <= line(node.end); index++)
        columnExceptions.add(index);
    }
    if (ts.isParenthesizedExpression(node)) return visit(node.expression);
    hash.update(`${node.kind}:${node.flags & ts.NodeFlags.BlockScoped}:`);
    if (ts.isPrefixUnaryExpression(node) || ts.isPostfixUnaryExpression(node))
      hash.update(`operator:${node.operator}:`);
    if (typeof node.text === 'string' && !ts.isSourceFile(node))
      hash.update(JSON.stringify(node.text));
    if (readable && ts.isStringLiteral(node) && node.getText(parsed).startsWith('"') &&
        !node.text.includes("'")) messages.push(`line ${line(node.getStart(parsed)) + 1}: prefer single quotes`);
    if (readable && ts.isBinaryExpression(node) &&
        line(node.left.end) !== line(node.operatorToken.getStart(parsed)))
      messages.push(`line ${line(node.operatorToken.getStart(parsed)) + 1}: break after the operator`);
    ts.forEachChild(node, visit);
    hash.update(';');
  };
  visit(parsed);
  if (readable) for (const [index, value] of file.content.split('\n').entries()) {
    // Preserve indivisible source excerpts in diagnostic comments for searching.
    // Do not exempt an ordinary long prose sentence or a line containing code.
    const sourceComment = value.match(/^\s*\/\/ (\S+)$/);
    const unbreakableComment = sourceComment && [...sourceComment[1]].length > 77;
    if ([...value].length > 80 && !columnExceptions.has(index) && !unbreakableComment)
      messages.push(`line ${index + 1}: exceeds 80 columns (${[...value].length})`);
    if (/[ \t]+$/.test(value)) messages.push(`line ${index + 1}: trailing whitespace`);
    if (/^ *\t/.test(value)) messages.push(`line ${index + 1}: indentation contains tabs`);
  }
  return {digest: hash.digest('hex'), messages};
}
// Declaration kinds and unary operators are scalar AST fields, not children.
// Ensure the comparison cannot accidentally erase either semantic distinction.
for (const [left, right] of [
  ['let x = 1;', 'const x = 1;'],
  ['const x = -value;', 'const x = +value;'],
  ["const x = 'before';", "const x = 'after';"],
]) {
  const digest = content => audit({path: 'audit.mjs', content}, 'javascript', false).digest;
  assert.notEqual(digest(left), digest(right));
}
// Exercise the column check independently of the generated corpus.
for (const [content, rejected] of [
  [`const value = [${Array(30).fill('123').join(', ')}];`, true],
  [`// ${'ordinary prose '.repeat(8)}`, true],
  [`import {value} from '${'module/'.repeat(15)}index.mjs';`, false],
  [`// ${'qualifiedName'.repeat(8)}`, false],
]) {
  const messages = audit({path: 'audit.mjs', content}, 'javascript', true).messages;
  assert.equal(messages.some(message => message.includes('exceeds 80 columns')), rejected);
}
// Continuations are distinct from array/object blocks and callback bodies.
for (const [content, rejected] of [
  ['call(\n  argument,\n);', true],
  ['call(\n    argument,\n);', false],
  ['const value = (\n    first +\n    second\n);', false],
  ['const value = [\n  first,\n  second,\n];', false],
  ['call(() => {\n  return value;\n});', false],
  ['const value =\n  first;', true],
  ['if (\n  first &&\n  second\n) {}', true],
]) {
  const messages = audit({path: 'audit.mjs', content}, 'javascript', true).messages;
  assert.equal(messages.some(message => message.includes('continuation needs')), rejected, content);
}
for (const [content, rejected] of [
  ['function f() {\n    return value;\n}', true],
  ['function f() {\n  return value;\n}', false],
]) {
  const messages = audit({path: 'audit.mjs', content}, 'javascript', true).messages;
  assert.equal(messages.some(message => message.includes('block statement needs')), rejected);
}
const parseJavaScript = content => ts.createSourceFile('audit.mjs', content,
  ts.ScriptTarget.ESNext, true, ts.ScriptKind.JS);
assert.equal(indentContinuations(ts, parseJavaScript(
  'call(\n  () => {\n    return value;\n  },\n);')),
  'call(\n    () => {\n      return value;\n    },\n);');
assert.throws(() => indentContinuations(ts,
  parseJavaScript('const value =\n  `first\nsecond`;')),
  /changed JavaScript tokens/);
const cache = new Map();
let checked = 0;
for (const source of specs) {
  const content = await readFile(path.join(root, source), 'utf8');
  for (const target of ['javascript', 'typescript']) {
    for (const machineBits of [32, 64]) {
      const result = JSON.parse(execFileSync(compiler, [], {
        input: JSON.stringify({method: 'planGeneration', target, machineBits,
          sources: [{path: source, content}]}), encoding: 'utf8',
        maxBuffer: 64 * 1024 * 1024,
      }));
      assert.deepEqual(result.diagnostics, [], `${source}/${target}`);
      const compact = JSON.parse(execFileSync(compiler, [], {
        input: JSON.stringify({method: 'planGeneration', target, machineBits,
          minify: true, sources: [{path: source, content}]}), encoding: 'utf8',
        maxBuffer: 64 * 1024 * 1024,
      }));
      assert.deepEqual(compact.diagnostics, []);
      assert.deepEqual(result.files.map(file => file.path), compact.files.map(file => file.path));
      const compactFiles = new Map(compact.files.map(file => [file.path, file]));
      const options = {parser: target === 'typescript' ? 'typescript' : 'babel',
        printWidth: 80, tabWidth: 2, singleQuote: true, bracketSpacing: false,
        semi: true, trailingComma: 'all', arrowParens: 'always'};
      for (const file of result.files.filter(file => /\.(mjs|ts)$/.test(file.path))) {
        const name = `${source}/${target}/${machineBits}/${file.path}`;
        const readableTree = audit(file, target, true);
        const compactTree = audit(compactFiles.get(file.path), target, false);
        assert.equal(readableTree.digest, compactTree.digest, `${name}: formatting changed AST`);
        if (readableTree.messages.length) violations.push({path: name, messages: readableTree.messages});
        const key = `${target}\n${file.content}`;
        if (!cache.has(key)) cache.set(key, await prettier.format(file.content, options));
        const formatted = cache.get(key);
        checked++;
        if (file.content === formatted) continue;
        const destination = path.join(root, '.artifacts/web-formatting', name);
        await mkdir(path.dirname(destination), {recursive: true});
        await writeFile(`${destination}.generated`, file.content);
        await writeFile(`${destination}.formatted`, formatted);
        mismatches.push(name);
      }
    }
  }
}
await writeFile(path.join(root, '.artifacts/web-formatting-report.json'),
  JSON.stringify({checked, violations, prettierDifferences: mismatches}, null, 2) + '\n');
assert.equal(violations.length, 0,
  `${violations.length}/${checked} artifacts violate audited rules; see .artifacts/web-formatting-report.json`);
console.log(`${checked} JS/TS artifacts pass continuation/column/quote/operator/whitespace and readable/compact AST checks`);
console.log(`${mismatches.length} artifacts differ from Prettier; snapshots are informational, not proof of full style conformance`);
