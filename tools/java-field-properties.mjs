import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {templates} from '../npm/templates.mjs';

const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const formatter = process.env.LAWSPEC_GOOGLE_JAVA_FORMAT;
assert.ok(compiler && formatter, 'Set LAWSPEC_CORE and LAWSPEC_GOOGLE_JAVA_FORMAT');
const source = (await readFile(path.join(root, 'test/fixtures/constructor_properties.lawspec'), 'utf8'))
  .replace('unit native.fields', 'unit fixture.fields') + `
sameSymbol :: Symbol -> Symbol -> Bool
law \`disjunctive fixture inputs\` is definition is
  \`for all\` (x :: Identity)
    (s :: Symbol where s == symbol("fixture", "same") || s == symbol("other", "same")) .
    sameSymbol s symbol("fixture", "same") = (s == symbol("fixture", "same"))
end end
`;
for (const machineBits of [32, 64]) {
  const readable = new Map();
  for (const minify of [false, true]) {
    const sourceDir = machineBits === 32 ? 'generated/source' : 'src/main/java';
    const testDir = machineBits === 32 ? 'generated/tests' : 'src/test/java';
    const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
      method: 'planGeneration', target: 'java', machineBits, minify, sourceDir, testDir,
      sources: [{path: 'fields.lawspec', content: source}],
    }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
    assert.deepEqual(result.diagnostics, []);
    const tests = result.files.find(file => file.path.endsWith('/FieldsLawSpecTest.java'));
    assert.ok(tests && tests.content.includes('law11Boundary0'));
    assert.ok(!tests.content.includes('law11Property'), 'Finite constructor domain must be exhaustive');
    const directory = path.join(root, '.artifacts/java-field-properties', `${machineBits}-${minify ? 'compact' : 'pretty'}`);
    for (const [name, content] of Object.entries(templates('java'))) {
      const destination = path.join(directory, name);
      await mkdir(path.dirname(destination), {recursive: true});
      await writeFile(destination, name === 'pom.xml' ? content.replace('<build>',
        `<build><sourceDirectory>${sourceDir}</sourceDirectory><testSourceDirectory>${testDir}</testSourceDirectory>`) : content);
    }
    let adapterPath;
    let adapterSource;
    for (const file of result.files) {
      assert.ok(file.path.startsWith(`${file.placement === 'test' ? testDir : sourceDir}/`));
      const destination = path.join(directory, file.path);
      await mkdir(path.dirname(destination), {recursive: true});
      await writeFile(destination, file.content);
      const formatted = execFileSync('java', ['-jar', formatter, destination], {encoding: 'utf8', maxBuffer: 32 * 1024 * 1024});
      await writeFile(destination + '.formatted', formatted);
      if (!minify) {
        readable.set(file.path, formatted);
        assert.equal(file.content, formatted, `Google Java Format: ${file.path}`);
      } else assert.equal(formatted, readable.get(file.path), `Compact parity: ${file.path}`);
      if (file.ownership === 'user') {
        adapterSource = file.content.replace(/throw new UnsupportedOperationException\(\s*"sameSymbol -> Bool"\s*\);/g, 'return lawspec.runtime.LawSpecRuntime.equal(value0, value1);')
          .replace(/throw new UnsupportedOperationException\([^;]+;/g, 'return value0;');
        assert.notEqual(adapterSource, file.content);
        adapterPath = destination;
        await writeFile(destination, adapterSource);
      }
    }
    const run = async (label, args = []) => {
      const result = spawnSync('mvn', ['-o', '-q', ...args, 'test'], {cwd: directory, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024});
      const log = (result.stdout ?? '') + (result.stderr ?? '');
      await writeFile(path.join(directory, `${label}.log`), log);
      return {...result, log};
    };
    const correct = await run('correct');
    assert.equal(correct.status, 0, correct.log);
    assert.ok(adapterPath);
    const mutant = adapterSource.replace('return value0;',
      'return new lawspec.data.Identity.IdentityCase(new lawspec.runtime.LawSpecRuntime.Value("Symbol", new lawspec.runtime.LawSpecRuntime.SymbolValue("same")));');
    assert.notEqual(mutant, adapterSource);
    try {
      await writeFile(adapterPath, mutant);
      const result = await run('identity-mutant', ['-Dtest=fixture.FieldsLawSpecTest']);
      assert.notEqual(result.status, 0);
      assert.match(result.log, /field refinement/);
      assert.doesNotMatch(result.log, /COMPILATION ERROR/);
    } finally {
      await writeFile(adapterPath, adapterSource);
    }
    const disjunction = adapterSource.replace('return lawspec.runtime.LawSpecRuntime.equal(value0, value1);', 'return true;');
    assert.notEqual(disjunction, adapterSource);
    try {
      await writeFile(adapterPath, disjunction);
      const result = await run('disjunction-mutant', ['-Dtest=fixture.FieldsLawSpecTest#law14Property']);
      assert.notEqual(result.status, 0);
      assert.match(result.log, /PropertyFalsified|AssertionFailedError/);
      assert.doesNotMatch(result.log, /COMPILATION ERROR|No tests/);
    } finally {
      await writeFile(adapterPath, adapterSource);
    }
    const strategies = result.files.find(file => file.path.endsWith('/LawSpecDataStrategies.java'));
    const strategyPath = path.join(directory, strategies.path);
    const formattedStrategies = await readFile(strategyPath + '.formatted', 'utf8');
    const errorMutant = formattedStrategies.replace('return new Checked(accepted.value(), null);',
      'return new Checked(null, new IllegalArgumentException("forced predicate evaluation error"));');
    assert.notEqual(errorMutant, formattedStrategies);
    try {
      await writeFile(strategyPath, errorMutant);
      const result = await run('evaluator-error', ['-Dtest=fixture.FieldsLawSpecTest#law0Property']);
      assert.notEqual(result.status, 0);
      assert.match(result.log, /forced predicate evaluation error/);
      assert.doesNotMatch(result.log, /COMPILATION ERROR|No tests/);
    } finally {
      await writeFile(strategyPath, strategies.content);
    }
    console.log(`Public Java constructor properties, native adapters and formatting pass: ${machineBits}, minify=${minify}`);
  }
}
