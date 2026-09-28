import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, mkdtemp, readFile, writeFile, symlink} from 'node:fs/promises';
import path from 'node:path';
import {planWrites, applyWrites} from '../npm/files.mjs';

const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
const fixture = process.env.LAWSPEC_WEB_DEFINITIONS_FIXTURE;
const tsc = process.env.LAWSPEC_TSC ?? path.join(root, '.artifacts/web-data-deps/typescript/bin/tsc');
const dependencies = path.join(root, '.artifacts/lists/javascript/node_modules');
assert.ok(compiler && fixture, 'Set LAWSPEC_CORE and LAWSPEC_WEB_DEFINITIONS_FIXTURE');
const source = await readFile(path.join(root, 'test/fixtures/total_definitions.lawspec'), 'utf8');
const description = "it's \\ a\n😀\u2028".repeat(8);
const other = `unit other
type Pair (a :: Type) (b :: Type) is Pair first :: a second :: b end
definition genericIdentity (x :: a) :: a is x end
definition genericCount (xs :: List a) :: BigInt is match xs with | Nil -> 0 | Cons head tail -> 1 + genericCount tail end end
law \`generic booleans\` is definition is \`for all\` (xs :: List Bool) . genericCount xs = prelude.length xs end end
law \`generic texts\` is definition is \`for all\` (xs :: List Text where genericCount xs > 0) . genericCount xs = prelude.length xs end end
definition size (x :: Bool) :: Bool is genericIdentity x end
definition quotedSymbol (x :: Unit) :: Symbol is symbol("quoted", ${JSON.stringify(description)}) end
definition pairCount (xs :: List (Pair Int8 Bool)) :: BigInt is genericCount xs end
law \`count products\` is
  definition is \`for all\` (xs :: List (Pair Int8 Bool)) . pairCount xs = prelude.length xs end
end
`;
for (const target of ['javascript', 'typescript']) {
  const ts = target === 'typescript';
  const extension = ts ? 'ts' : 'mjs';
  const importExtension = ts ? 'js' : 'mjs';
  for (const machineBits of [32, 64]) {
    const sourceDir = machineBits === 32 ? 'library/native' : 'src';
    const testDir = machineBits === 32 ? 'checks/generated' : 'test';
    const sources = [{path: 'total.lawspec', content: source}, {path: 'other.lawspec', content: other}];
    const result = JSON.parse(execFileSync(compiler, [], {input: JSON.stringify({
      method: 'planGeneration', target, machineBits, sourceDir, testDir, sources,
    }), encoding: 'utf8', maxBuffer: 32 * 1024 * 1024}));
    assert.deepEqual(result.diagnostics, []);
    const directory = path.join(root, `.artifacts/web-definitions/${target}/${machineBits}`);
    const generated = [];
    const tests = [];
    let adapter;
    let adapterSource;
    for (const file of result.files) {
      assert.ok(file.path.startsWith(`${file.placement === 'test' ? testDir : sourceDir}/`));
      const destination = path.join(directory, file.path);
      await mkdir(path.dirname(destination), {recursive: true});
      let content = file.content;
      if (file.path.endsWith(`/example/total.${extension}`) && file.ownership === 'user') {
        assert.doesNotMatch(content, /function (size|sumList|sumTree|increment)\(/);
        content = content.replace(/throw new Error\((["'])actualSum\1\);/, 'return value0.reduce((sum, x) => sum + BigInt(x), 0n);')
          .replace(/throw new Error\((["'])actualIncrement\1\);/, 'return BigInt(value0) + 1n;')
          .replace(/throw new Error\((["'])actualTree\1\);/,
            'return value0 instanceof data.TreeLeaf ? BigInt(value0.value) : actualTree(value0.left) + actualTree(value0.right);');
        adapter = file;
        adapterSource = content;
      }
      if (file.path.includes('/lawspec_definitions/') || file.path.endsWith(`/lawspec_definition_bodies.${extension}`)) {
        assert.equal(file.ownership, 'generated');
        assert.equal(file.placement, 'source');
        assert.doesNotMatch(content, /@ts-nocheck|\bany\b/);
        for (const [index, line] of content.split('\n').entries()) {
          assert.ok(line.length <= 80, `${file.path}:${index + 1}: line exceeds 80 columns`);
          assert.doesNotMatch(line, /[ \t]+$/);
        }
        generated.push({file, destination, content});
      }
      if (file.placement === 'source') assert.doesNotMatch(content, /from ['"]fast-check['"]|from ['"]node:test['"]/);
      if (file.path.includes('.lawspec.test.')) tests.push(path.join(ts ? 'dist' : '', file.path.replace(/\.ts$/, '.js')));
      await writeFile(destination, content);
    }
    assert.equal(generated.length, 3);
    await writeFile(path.join(directory, 'package.json'), '{"type":"module"}\n');
    const options = {target: 'ES2022', module: 'NodeNext', strict: true, rootDir: '.', outDir: 'dist', skipLibCheck: true};
    const nativeConfig = path.join(directory, 'tsconfig.native.json');
    if (ts) {
      await writeFile(path.join(directory, sourceDir, 'definition-types.ts'), await readFile(path.join(root, 'test/runtime/WebDefinitionTypes.ts'), 'utf8'));
      await writeFile(nativeConfig, JSON.stringify({compilerOptions: options, include: [`${sourceDir}/**/*.ts`]}));
      execFileSync(process.execPath, [tsc, '-p', nativeConfig], {stdio: 'inherit'});
    }
    const env = {...process.env,
      LAWSPEC_DEFINITIONS_DIR: path.join(directory, ts ? 'dist' : '', sourceDir),
      LAWSPEC_DATA_EXTENSION: importExtension,
      LAWSPEC_MACHINE_BITS: String(machineBits),
    };
    function native() {
      execFileSync(process.execPath, [path.join(root, 'test/runtime/WebDefinitionsCheck.mjs')], {env, stdio: 'inherit'});
    }
    native();
    await symlink(dependencies, path.join(directory, 'node_modules')).catch(error => {
      if (error.code !== 'EEXIST') throw error;
    });
    if (ts) await writeFile(path.join(directory, 'tsconfig.json'), JSON.stringify({
      compilerOptions: options, include: [`${sourceDir}/**/*.ts`, `${testDir}/**/*.ts`],
    }));
    async function run(label) {
      if (ts) execFileSync(process.execPath, [tsc, '-p', directory], {stdio: 'inherit'});
      const result = spawnSync(process.execPath, ['--test', ...tests], {
        cwd: directory, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
      });
      const log = (result.stdout ?? '') + (result.stderr ?? '');
      await writeFile(path.join(directory, `${label}.log`), log);
      return {...result, log};
    }
    const correct = await run('correct');
    assert.equal(correct.status, 0, correct.log);
    for (const [label, from, to] of [
      ['sum', 'value0.reduce((sum, x) => sum + BigInt(x), 0n)', '0n'],
      ['overflow', 'BigInt(value0) + 1n', 'BigInt((value0 + 1) << 24 >> 24)'],
      ['tree', 'actualTree(value0.left) + actualTree(value0.right)', '0n'],
    ]) {
      const mutation = adapterSource.replace(from, to);
      assert.notEqual(mutation, adapterSource);
      await writeFile(path.join(directory, adapter.path), mutation);
      const result = await run(label);
      assert.notEqual(result.status, 0, `mutant exposed: ${label}`);
      assert.match(result.log, label === 'sum' ? /Error: actualSum postcondition:/ : /AssertionError/);
      assert.doesNotMatch(result.log, /SyntaxError|ReferenceError|ERR_MODULE_NOT_FOUND/);
    }
    await writeFile(path.join(directory, adapter.path), adapterSource);
    const sourcePaths = [];
    for (const item of sources) {
      const file = path.join(directory, item.path);
      await writeFile(file, item.content);
      sourcePaths.push(file);
    }
    execFileSync(fixture, [target, String(machineBits), directory, sourceDir, ...sourcePaths]);
    assert.ok((await readFile(generated[0].destination, 'utf8')).length < generated[0].content.length);
    const compact = await run('compact');
    assert.equal(compact.status, 0, compact.log);
    native();
    for (const item of generated) await writeFile(item.destination, item.content);
    const regeneration = await mkdtemp(path.join(directory, 'regeneration-'));
    await applyWrites([await planWrites(regeneration, result.files)]);
    await writeFile(path.join(regeneration, adapter.path), adapterSource);
    assert.equal((await planWrites(regeneration, result.files)).changes.length, 0);
    await writeFile(path.join(regeneration, generated[0].file.path), '// edited generated definition\n');
    await assert.rejects(planWrites(regeneration, result.files), /edited generated file/);
    console.log(`${target} definitions, native calls, properties, compact source, ownership and mutants passed: ${machineBits}`);
  }
}
