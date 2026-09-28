import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFile, writeFile, symlink} from 'node:fs/promises';
import path from 'node:path';
const root = path.resolve(import.meta.dirname, '..');
const directory = path.join(root, '.artifacts/web-native-data');
const dependencies = path.join(root, '.artifacts/lists/javascript/node_modules');
const fixture = process.env.LAWSPEC_WEB_DATA_FIXTURE;
const tsc = process.env.LAWSPEC_TSC ?? path.join(
  root, '.artifacts/web-data-deps/typescript/bin/tsc');
assert.ok(fixture, 'Set LAWSPEC_WEB_DATA_FIXTURE');
execFileSync(fixture, [directory]);
for (const target of ['javascript', 'typescript']) {
  for (const mode of ['pretty', 'compact']) {
    const project = path.join(directory, target, mode);
    await writeFile(path.join(project, 'package.json'), '{"type":"module"}\n');
    await symlink(dependencies, path.join(project, 'node_modules')).catch(error => {
      if (error.code !== 'EEXIST') throw error;
    });
    const support = await readFile(path.join(
      root, 'runtime/lawspec_data_strategies.mjs'), 'utf8');
    await writeFile(path.join(project, 'src/lawspec_data_strategies.' +
      (target === 'typescript' ? 'ts' : 'mjs')), target === 'typescript' ?
      '// @ts-nocheck\n' + support.replace(
        "from './lawspec_runtime.mjs'", "from './lawspec_runtime.js'").replace(
        "from './lawspec_schema.mjs'", "from './lawspec_schema.js'") : support);
    if (target === 'typescript') {
      await writeFile(path.join(project, 'src/type-check.ts'),
        await readFile(path.join(root, 'test/runtime/WebDataTypes.ts'), 'utf8'));
      await writeFile(path.join(project, 'tsconfig.json'), JSON.stringify({
        compilerOptions: {target: 'ES2022', module: 'NodeNext', strict: true,
          rootDir: 'src', outDir: 'dist', skipLibCheck: true},
        include: ['src/**/*.ts'],
      }));
      execFileSync(process.execPath, [tsc, '-p', project], {stdio: 'inherit'});
    }
    for (const bits of [32, 64]) {
      execFileSync(process.execPath, ['--test',
        path.join(root, 'test/runtime/WebDataCheck.mjs'),
        path.join(root, 'test/runtime/WebDataStrategiesCheck.mjs'),
        path.join(root, 'test/runtime/WebConstructorContractsCheck.mjs')], {
        env: {...process.env,
          LAWSPEC_FAST_CHECK: path.join(dependencies, 'fast-check/lib/fast-check.js'),
          LAWSPEC_DATA_DIR: path.join(project, target === 'typescript' ? 'dist' : 'src'),
          LAWSPEC_DATA_EXTENSION: target === 'typescript' ? 'js' : 'mjs',
          LAWSPEC_MACHINE_BITS: String(bits),
        }, stdio: 'inherit',
      });
    }
    console.log(`${target} native data passed: ${mode}`);
  }
}
