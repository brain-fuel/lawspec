import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';
import {templates} from '../npm/templates.mjs';

const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
assert.ok(compiler, 'Set LAWSPEC_CORE');
const source = await readFile(path.join(root, 'test/fixtures/constructor_properties.lawspec'), 'utf8') + `
machineAdapter :: Machine -> Machine
law \`native machine adapter\` is
  definition is \`for all\` (x :: Machine) . machineAdapter x = x end
end
`;
const nativeBits = Number(execFileSync('rustc', ['--print', 'cfg'], {encoding: 'utf8'})
  .match(/target_pointer_width="(32|64)"/)[1]);
for (const machineBits of [32, 64]) {
  const readable = new Map();
  for (const minify of [false, true]) {
    const sourceDir = machineBits === 32 ? 'library/native' : 'src';
    const testDir = machineBits === 32 ? 'checks/properties' : 'tests';
    const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
      method: 'planGeneration', target: 'rust', machineBits, minify, sourceDir, testDir,
      sources: [{path: 'fields.lawspec', content: source}],
    }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
    assert.deepEqual(result.diagnostics, []);
    const directory = path.join(root, '.artifacts/rust-field-properties', `${machineBits}-${minify ? 'compact' : 'pretty'}`);
    await mkdir(path.join(directory, sourceDir), {recursive: true});
    const scaffold = templates('rust');
    const test = result.files.find(file => file.path.endsWith('_lawspec.rs'));
    assert.ok(test);
    await writeFile(path.join(directory, 'Cargo.toml'), scaffold['Cargo.toml'] +
      `\n[lib]\npath="${sourceDir}/lib.rs"\n[[test]]\nname="properties"\npath="${test.path}"\n`);
    await writeFile(path.join(directory, sourceDir, 'lib.rs'), scaffold['src/lib.rs']);
    let adapterPath;
    let adapterSource;
    for (const file of result.files) {
      const destination = path.join(directory, file.path);
      await mkdir(path.dirname(destination), {recursive: true});
      let content = file.content;
      if (file.path.endsWith('.rs')) {
        const formatted = execFileSync('rustfmt', ['--edition', '2024', '--config', 'skip_children=true'], {
          input: content, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
        });
        if (!minify) {
          readable.set(file.path, formatted);
          await writeFile(destination + '.rustfmt', formatted);
          await writeFile(destination + '.generated', content);
          assert.equal(content, formatted, `rustfmt: ${file.path}`);
        } else {
          assert.equal(formatted, readable.get(file.path), `compact parity: ${file.path}`);
        }
      }
      if (file.ownership === 'user') {
        content = content.replace(/todo!\("native.fields::(?:echoAdapter|machineAdapter)"\)/g, 'value0');
        assert.notEqual(content, file.content);
        adapterPath = destination;
        adapterSource = content;
      }
      await writeFile(destination, content);
    }
    const run = async (label, args) => {
      const result = spawnSync('cargo', ['test', '--offline', '--quiet', ...args], {
        cwd: directory, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024,
        env: {...process.env, CARGO_TARGET_DIR: path.join(root, '.artifacts/rust-field-properties/target')},
      });
      const log = (result.stdout ?? '') + (result.stderr ?? '');
      await writeFile(path.join(directory, `${label}.log`), log);
      return {...result, log};
    };
    const correct = await run('correct', ['--test', 'properties', '--', '--skip', 'test_14']);
    assert.equal(correct.status, 0, correct.log);
    const architecture = await run('architecture', ['--test', 'properties', 'test_14', '--', '--exact']);
    if (machineBits === nativeBits) assert.equal(architecture.status, 0, architecture.log);
    else {
      assert.notEqual(architecture.status, 0);
      assert.match(architecture.log, /machineBits does not match native architecture/);
    }
    assert.ok(adapterPath);
    const mutant = adapterSource.replace(/\bvalue0\s*}/,
      'crate::lawspec_data::Identity::Identity { value: ls::Symbol::new("same".into()) } }');
    assert.notEqual(mutant, adapterSource);
    try {
      await writeFile(adapterPath, mutant);
      const bad = await run('identity-mutant', ['--test', 'properties', 'test_0', '--', '--exact']);
      assert.notEqual(bad.status, 0);
      assert.match(bad.log, /field refinement/);
      assert.doesNotMatch(bad.log, /error\[E\d+\]/);
    } finally {
      await writeFile(adapterPath, adapterSource);
    }
    const randomOnly = (content, index) => {
      const formatted = execFileSync('rustfmt', ['--edition', '2024', '--config', 'skip_children=true'], {
        input: content, encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
      });
      const start = formatted.indexOf(`fn test_${index}() -> ls::Result<()> {`);
      const body = formatted.indexOf('    let strategy = proptest::strategy::Just', start);
      assert.ok(start >= 0 && body > start);
      return formatted.slice(0, start) + `fn test_${index}() -> ls::Result<()> {\n` + formatted.slice(body);
    };
    const testPath = path.join(directory, test.path);
    const strategies = result.files.find(file => file.path.endsWith('/lawspec_strategies.rs'));
    const strategyPath = path.join(directory, strategies.path);
    try {
      await writeFile(testPath, randomOnly(test.content, 0));
      const faulty = strategies.content.replace('Some(Ok(value))', 'Some(Err("forced predicate evaluation error".into()))');
      assert.notEqual(faulty, strategies.content);
      await writeFile(strategyPath, faulty);
      const error = await run('evaluator-error', ['--test', 'properties', 'test_0', '--', '--exact']);
      assert.notEqual(error.status, 0);
      assert.match(error.log, /forced predicate evaluation error/);
      assert.doesNotMatch(error.log, /error\[E\d+\]|index out of bounds|Too many local rejects/);
    } finally {
      await writeFile(testPath, test.content);
      await writeFile(strategyPath, strategies.content);
    }
    const negative = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
      method: 'planGeneration', target: 'rust', machineBits, minify, sourceDir, testDir,
      sources: [{path: 'fields.lawspec', content: source + `
law \`disjunction retains other identities\` is definition is
  \`for all\` (x :: Identity)
    (s :: Symbol where s == symbol("fixture", "same") || s != symbol("fixture", "same")) .
  s = symbol("fixture", "same")
end end
`}],
    }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
    assert.deepEqual(negative.diagnostics, []);
    const negativeTest = negative.files.find(file => file.path === test.path);
    try {
      await writeFile(testPath, randomOnly(negativeTest.content, 15));
      const rejected = await run('disjunction', ['--test', 'properties', 'test_15', '--', '--exact']);
      assert.notEqual(rejected.status, 0);
      assert.match(rejected.log, /disjunction retains other identities/);
      assert.doesNotMatch(rejected.log, /error\[E\d+\]|Too many local rejects/);
    } finally {
      await writeFile(testPath, test.content);
    }
    console.log(`Rust public constructor properties, architecture, identity mutant and formatting passed: ${machineBits} ${minify}`);
  }
}
