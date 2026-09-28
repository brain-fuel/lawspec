import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile} from 'node:fs/promises';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const python = process.env.LAWSPEC_PYTHON ?? 'python3.13';
assert.ok(compiler, 'Set LAWSPEC_CORE');
const source = await readFile(path.join(root, 'test/fixtures/python_constructor_fields.lawspec'), 'utf8') + `
echoAdapter :: Identity -> Identity
law \`adapter identity\` is definition is \`for all\` (x :: Identity) . echoAdapter x = x end end
law \`positive gap\` is definition is \`for all\` (x :: Gap) . inverseGap x > 0 end end
law \`fixture identity\` is definition is \`for all\` (x :: Identity) . echoIdentity x = x end end
law \`nonempty bucket\` is definition is \`for all\` (x :: Bucket Int8) . echoBucket x = x end end
law \`positive elements\` is definition is \`for all\` (x :: Positives) . echoPositives x = x end end
law \`sum alternatives\` is definition is \`for all\` (x :: Choice) . echoChoice x = x end end
law \`machine field\` is definition is \`for all\` (x :: Machine) . echoMachine x = x end end
law \`guarded field\` is definition is \`for all\` (x :: Guarded) . echoGuarded x = x end end
law \`mixed fixture inputs\` is definition is \`for all\` (x :: Identity) (s :: Symbol where s == symbol("fixture", "same")) . echoIdentity x = x end end
law \`nested identities\` is definition is \`for all\` (xs :: List Identity) . xs = xs end end
`;
for (const machineBits of [32, 64]) {
  for (const minify of [false, true]) {
    const sourceDir = machineBits === 32 ? 'library/native' : 'src';
    const testDir = machineBits === 32 ? 'checks/properties' : 'tests';
    const result = JSON.parse(execFileSync(compiler, [], {
      input: JSON.stringify({method: 'planGeneration', target: 'python', machineBits,
        minify, sourceDir, testDir, sources: [{path: 'fields.lawspec', content: source}]}),
      encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
    }));
    assert.deepEqual(result.diagnostics, []);
    const directory = path.join(root, '.artifacts/python-field-properties',
      `${machineBits}-${minify ? 'compact' : 'pretty'}`);
    let adapterPath;
    let adapterSource;
    for (const file of result.files) {
      const destination = path.join(directory, file.path);
      await mkdir(path.dirname(destination), {recursive: true});
      let content = file.content;
      if (file.ownership === 'user' && content.includes('echoAdapter')) {
        content = content.replace('raise NotImplementedError("echoAdapter")', 'return value0');
        assert.notEqual(content, file.content);
        adapterPath = destination;
        adapterSource = content;
      }
      await writeFile(destination, content);
    }
    const env = {...process.env, PYTHONDONTWRITEBYTECODE: '1',
      PYTHONPATH: [path.join(directory, sourceDir), path.join(directory, testDir),
        path.join(root, '.artifacts/python-data-deps')].join(path.delimiter)};
    const check = spawnSync(python, ['-m', 'pytest', '-q', '--tb=short', testDir], {
      cwd: directory, env, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
    });
    const log = (check.stdout ?? '') + (check.stderr ?? '');
    await writeFile(path.join(directory, 'pytest.log'), log);
    assert.equal(check.status, 0, log);
    if (!minify && process.env.LAWSPEC_PYCODESTYLE) {
      execFileSync(python, [process.env.LAWSPEC_PYCODESTYLE, '--max-line-length=79',
        '--max-doc-length=72', path.join(directory, sourceDir), path.join(directory, testDir)]);
    }
    assert.ok(adapterPath);
    try {
      const mutant = adapterSource.replace('return value0',
        'return type(value0)(type(value0.value)("same"))');
      assert.notEqual(mutant, adapterSource);
      await writeFile(adapterPath, mutant);
      const rejected = spawnSync(python, ['-m', 'pytest', '-q', '-x', '--tb=short', testDir], {
        cwd: directory, env, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
      });
      const failure = (rejected.stdout ?? '') + (rejected.stderr ?? '');
      await writeFile(path.join(directory, 'mutant.log'), failure);
      assert.notEqual(rejected.status, 0, 'Symbol-description adapter mutant survived');
      assert.match(failure, /field refinement/);
      assert.doesNotMatch(failure, /SyntaxError|ImportError|NameError|ERROR collecting/);
    } finally {
      await writeFile(adapterPath, adapterSource);
    }
    const disjunction = source + `
law \`disjunction retains other identities\` is
  definition is \`for all\` (x :: Identity)
    (s :: Symbol where s == symbol("fixture", "same") || s != symbol("fixture", "same")) .
    s = symbol("fixture", "same")
  end
end
`;
    const negative = JSON.parse(execFileSync(compiler, [], {
      input: JSON.stringify({method: 'planGeneration', target: 'python', machineBits,
        minify, sourceDir, testDir, sources: [{path: 'fields.lawspec', content: disjunction}]}),
      encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
    }));
    assert.deepEqual(negative.diagnostics, []);
    const testFile = negative.files.find(file => file.path.endsWith('test_native_fields_lawspec.py'));
    const original = result.files.find(file => file.path === testFile.path);
    const lastProperty = [...testFile.content.matchAll(/def (test_law\d+_property)\(/g)].at(-1)[1];
    try {
      await writeFile(path.join(directory, testFile.path), testFile.content);
      const rejected = spawnSync(python, ['-m', 'pytest', '-q', '--tb=short',
        `${testFile.path}::${lastProperty}`], {
        cwd: directory, env, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
      });
      const failure = (rejected.stdout ?? '') + (rejected.stderr ?? '');
      await writeFile(path.join(directory, 'disjunction.log'), failure);
      assert.notEqual(rejected.status, 0, 'Disjunction was narrowed to one identity');
      assert.match(failure, /AssertionError/);
      assert.doesNotMatch(failure, /FailedHealthCheck|SyntaxError|ImportError|NameError/);
    } finally {
      await writeFile(path.join(directory, testFile.path), original.content);
    }
    console.log(`Python public field properties passed: ${machineBits}, minify=${minify}`);
  }
}

const parity = execFileSync(python, ['-c', `
import ast
from pathlib import Path
import sys
root = Path(sys.argv[1])
count = 0
for bits in (32, 64):
    pretty = root / f"{bits}-pretty"
    compact = root / f"{bits}-compact"
    for source in pretty.rglob("*.py"):
        other = compact / source.relative_to(pretty)
        assert ast.dump(ast.parse(source.read_text())) == ast.dump(
            ast.parse(other.read_text())), str(source)
        count += 1
print(f"{count} public Python artifacts preserve readable/compact AST parity")
`, path.join(root, '.artifacts/python-field-properties')], {encoding: 'utf8'});
process.stdout.write(parity);
