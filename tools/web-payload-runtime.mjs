import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile, copyFile} from 'node:fs/promises';
import {createRequire} from 'node:module';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const directory = path.join(root, '.artifacts/web-payload-runtime');
const test = path.join(root, 'test/runtime/WebPayloadCheck.mjs');
await mkdir(directory, {recursive: true});
const run = (dir, extension = 'mjs') => spawnSync(process.execPath, ['--test', test], {
  env: {...process.env, LAWSPEC_DATA_DIR: dir, LAWSPEC_DATA_EXTENSION: extension},
  encoding: 'utf8', timeout: 30000,
});
const succeeds = result => {
  assert.equal(result.error, undefined);
  assert.equal(result.status, 0, result.stdout + result.stderr);
};
for (const name of ['lawspec_schema.mjs', 'lawspec_runtime.mjs']) {
  await copyFile(path.join(root, 'runtime', name), path.join(directory, name));
}
succeeds(run(directory));
const file = path.join(directory, 'lawspec_schema.mjs');
const source = await readFile(file, 'utf8');
for (const [before, after] of [
  ['return args[field.index]', 'return args[0]'],
  [': null;\n    };\n    const contextual', ': new Parameter(0);\n    };\n    const contextual'],
  ['const checked = this.validate(type, value, bits, symbols);\n    const recipe',
    'const checked = value;\n    const recipe'],
  ['return result;\n      }\n      const {name, args} = plan;',
    'return true;\n      }\n      const {name, args} = plan;'],
]) {
  assert.ok(source.includes(before), before);
  try {
    await writeFile(file, source.replace(before, after));
    const result = run(directory);
    assert.equal(result.error, undefined);
    assert.notEqual(result.status, 0, `Payload mutant survived: ${before}`);
    assert.match(result.stdout, /recursive parameter occurrences/);
    assert.doesNotMatch(result.stderr, /SyntaxError/);
  } finally {
    await writeFile(file, source);
  }
}
console.log('Web payload runtime: eight checks pass; four mutants rejected');
if (process.env.LAWSPEC_CORE) {
  const require = createRequire(import.meta.url);
  const ts = require(path.join(root, '.artifacts/web-data-deps/typescript/lib/typescript.js'));
  const content = await readFile(path.join(root, 'examples/specs/data_types.lawspec'), 'utf8');
  for (const target of ['javascript', 'typescript']) {
    for (const machineBits of [32, 64]) {
      for (const minify of [false, true]) {
        const result = JSON.parse(execFileSync(process.env.LAWSPEC_CORE, [], {
          input: JSON.stringify({method: 'planGeneration', target, machineBits, minify,
            sources: [{path: 'data.lawspec', content}]}), encoding: 'utf8',
          maxBuffer: 32 * 1024 * 1024,
        }));
        assert.deepEqual(result.diagnostics, []);
        const output = path.join(directory, `${target}-${machineBits}-${minify}`);
        await mkdir(output, {recursive: true});
        await writeFile(path.join(output, 'package.json'), '{"type":"module"}\n');
        const inputExtension = target === 'typescript' ? 'ts' : 'mjs';
        const extension = target === 'typescript' ? 'js' : 'mjs';
        for (const name of ['lawspec_schema', 'lawspec_runtime']) {
          const artifact = result.files.find(file => file.path.endsWith(`/${name}.${inputExtension}`));
          assert.ok(artifact, name);
          let source = artifact.content;
          if (target === 'typescript') {
            source = ts.transpileModule(source, {compilerOptions: {
              target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.ESNext,
            }}).outputText;
          }
          await writeFile(path.join(output, `${name}.${extension}`), source);
        }
        succeeds(run(output, extension));
      }
    }
  }
  console.log('Generated JS/TS payload runtimes pass at both widths and layouts');
}
