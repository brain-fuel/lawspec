// Generated from templates/editors/vscode/test/grammar.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { test } from 'node:test';
import textmate from 'vscode-textmate';
import oniguruma from 'vscode-oniguruma';

const require = createRequire(import.meta.url);
const source = await readFile(new URL('../syntaxes/lawspec.tmLanguage.json', import.meta.url), 'utf8');
const wasm = await readFile(require.resolve('vscode-oniguruma/release/onig.wasm'));
await oniguruma.loadWASM(wasm.buffer.slice(wasm.byteOffset, wasm.byteOffset + wasm.byteLength));
const registry = new textmate.Registry({
  onigLib: Promise.resolve({
    createOnigScanner: patterns => new oniguruma.OnigScanner(patterns),
    createOnigString: value => new oniguruma.OnigString(value),
  }),
  loadGrammar: async scope => scope === 'source.lawspec'
    ? textmate.parseRawGrammar(source, 'lawspec.tmLanguage.json') : null,
});
const grammar = await registry.loadGrammar('source.lawspec');

function tokens(line, state = textmate.INITIAL) {
  return grammar.tokenizeLine(line, state);
}
function scopeAt(line, fragment, expected) {
  const position = line.indexOf(fragment);
  assert.ok(position >= 0, `Missing fixture fragment ${fragment}`);
  const token = tokens(line).tokens.find(t => t.startIndex <= position && position < t.endIndex);
  assert.ok(token?.scopes.includes(expected + '.lawspec'),
    `${JSON.stringify(fragment)} in ${JSON.stringify(line)}: ${token?.scopes.join(', ')}`);
}

test('declarations, quantifiers, refinements, constraints, and match branches', () => {
  for (const [line, fragment, scope] of [
    ['unit example.collections', 'unit', 'keyword.control'],
    ['unit example.collections', 'example.collections', 'entity.name.namespace'],
    ['import shop.money as money', 'import', 'keyword.control.import'],
    ['import shop.money as money', 'shop.money', 'entity.name.namespace'],
    ['import shop.money as money', 'as', 'keyword.control.import'],
    ['law `reversing twice` is', 'law', 'keyword.control'],
    ['law `reversing twice` is', '`reversing twice`', 'entity.name.function.law'],
    ['definition is `for all` (xs :: List Int32) . xs = xs end', '`for all`', 'keyword.control.quantifier'],
    ['definition is `involution` reverse end', '`involution`', 'entity.name.function.law'],
    ['refinement Positive is (x :: Int8 where x > 0) end', 'Positive', 'entity.name.type'],
    ['refinement Positive is (x :: Int8 where x > 0) end', 'where', 'keyword.control'],
    ['type Tree (a :: Type) is', 'Tree', 'entity.name.type'],
    ['definition size (xs :: List a) :: Integer is', 'size', 'entity.name.function'],
    ['reverse :: List a -> List a', 'reverse', 'entity.name.function'],
    ['requires Eq a', 'Eq', 'support.type.class'],
    ['requires Integer a', 'Integer', 'support.type'],
    ['match xs with | Cons x rest -> x end', 'match', 'keyword.control'],
    ['match xs with | Cons x rest -> x end', 'Cons', 'support.function.constructor'],
    ['match xs with | Cons x rest -> x end', '|', 'punctuation.separator.branch'],
    ['type Δέντρο (α :: Type) is', 'Δέντρο', 'entity.name.type'],
    ['(α :: Int8)', 'α', 'variable.parameter'],
  ]) scopeAt(line, fragment, scope);
});

test('all keywords have theme-compatible keyword scopes', () => {
  for (const word of 'unit law requires is end definition description rationale example expect implies and references are where refinement type match with'.split(' ')) {
    scopeAt(word, word, 'keyword.control');
  }
});

test('primitives, scalar constructors, numbers, and operators', () => {
  for (const type of 'Bool Int8 Int16 Int32 Int64 UInt8 UInt16 UInt32 UInt64 IntSize UIntSize UIntPtr Integer BigInt BigUInt Decimal Rational Float32 Float64 Complex64 Complex128 Char CodePoint CodeUnit16 Text CodePointText Utf16Text Bytes Symbol Unit Null Undefined Nullable Optional List Maybe Either Type'.split(' ')) {
    scopeAt(`(x :: ${type})`, type, 'support.type');
  }
  for (const constructor of 'rational decimal symbol bytes codePoints utf16 char codePoint codeUnit16 float32Bits float64Bits complex64 complex128 nullable optional'.split(' ')) {
    scopeAt(`${constructor}(0)`, constructor, 'support.function');
  }
  for (const number of ['127', '18446744073709551615', '0.1', '1e-30', '2.5E+12']) {
    scopeAt(`x = -${number}`, number, 'constant.numeric');
  }
  for (const op of ['+', '-', '*', '/', '<=', '>=', '==', '!=', '<', '>', '&&', '||', '!', '.', '=']) {
    scopeAt(`x ${op} y`, op, 'keyword.operator');
  }
  scopeAt('prelude.isNaN x', 'prelude.isNaN', 'support.function');
  scopeAt('Int8.max - x', 'Int8.max', 'constant.language.bound');
  scopeAt('a.min', 'a.min', 'constant.language.bound');
  scopeAt('x-1', '-', 'keyword.operator');
  scopeAt('f -42', '42', 'constant.numeric');
  for (const constant of ['true', 'false', 'unitValue', 'null', 'undefined']) {
    scopeAt(constant, constant, 'constant.language');
  }
});

test('comments, strings, quoted names, and identifier boundaries isolate keywords', () => {
  scopeAt('-- law `name` Int8 42', 'law', 'comment.line.double-dash');
  scopeAt('"law -- true Int8"', 'law', 'string.quoted.double');
  scopeAt('`law true Int8 -- name`', 'true', 'entity.name.function.law');
  scopeAt(String.raw`"escaped \" law" end`, 'law', 'string.quoted.double');
  scopeAt(String.raw`"escaped \" law" end`, 'end', 'keyword.control');
  scopeAt(String.raw`"\n\x41"`, '\\n', 'constant.character.escape');
  for (const name of ['laws', 'law_name', 'law2', 'true_value', 'unitValueSuffix', 'lawα']) {
    scopeAt(name, name, 'variable.other');
  }
  const broken = tokens('`unfinished law name');
  const next = tokens('expect true = true', broken.ruleStack);
  assert.ok(next.tokens[0].scopes.includes('keyword.control.lawspec'));
});

test('extension registers the grammar and valid editor configuration', async () => {
  const manifest = JSON.parse(await readFile(new URL('../package.json', import.meta.url)));
  const contribution = manifest.contributes.grammars[0];
  assert.equal(contribution.scopeName, JSON.parse(source).scopeName);
  assert.equal(manifest.contributes.languages[0].id, contribution.language);
  assert.deepEqual(manifest.contributes.languages[0].extensions, ['.lawspec']);
  const config = JSON.parse(await readFile(new URL('../language-configuration.json', import.meta.url)));
  assert.equal(config.comments.lineComment, '--');
  assert.equal(await readFile(new URL('../LICENSE', import.meta.url), 'utf8'),
    await readFile(new URL('../../../LICENSE', import.meta.url), 'utf8'));
});

test('every bundled spec and parser fixture tokenizes without stopping early', async () => {
  let files = 0;
  for (const directory of ['examples/specs/', 'npm/examples/specs/', 'test/fixtures/']) {
    const base = new URL('../../../' + directory, import.meta.url);
    for (const file of await readdir(base)) {
      if (!file.endsWith('.lawspec')) continue;
      let state = textmate.INITIAL;
      const lines = (await readFile(new URL(file, base), 'utf8')).split(/\r?\n/);
      for (const line of lines) {
        const result = grammar.tokenizeLine(line, state, 1000);
        assert.equal(result.stoppedEarly, false, `${directory}${file}: ${line}`);
        state = result.ruleStack;
      }
      files++;
    }
  }
  assert.ok(files >= 50, `Expected all repository specs, found ${files}`);
});
