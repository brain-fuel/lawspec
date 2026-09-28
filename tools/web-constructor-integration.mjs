import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {readFile, writeFile, readdir, symlink} from 'node:fs/promises';
import {createRequire} from 'node:module';
import path from 'node:path';
import {continuationViolations} from './web-continuations.mjs';

const root = path.resolve(import.meta.dirname, '..');
const directory = path.join(root, '.artifacts/web-constructor-output');
const fixture = process.env.LAWSPEC_WEB_CONSTRUCTOR_FIXTURE;
assert.ok(fixture, 'Set LAWSPEC_WEB_CONSTRUCTOR_FIXTURE');
const require = createRequire(import.meta.url);
const ts = require(path.join(root, '.artifacts/web-data-deps/typescript/lib/typescript.js'));
const tsc = path.join(root, '.artifacts/web-data-deps/typescript/bin/tsc');
execFileSync(fixture, [path.join(root, 'test/fixtures/python_constructor_fields.lawspec'), directory]);
const dependencies = path.join(root, '.artifacts/lists/javascript/node_modules');
const strategies = await readFile(path.join(root, 'runtime/lawspec_data_strategies.mjs'), 'utf8');
async function files(directory) {
  const entries = await readdir(directory, {withFileTypes: true});
  return (await Promise.all(entries.map(async entry => entry.isDirectory()
    ? files(path.join(directory, entry.name)) : [path.join(directory, entry.name)]))).flat();
}
function tree(node, source) {
  if (ts.isParenthesizedExpression(node)) return tree(node.expression, source);
  const result = [node.kind, node.flags & ts.NodeFlags.BlockScoped];
  if (!ts.isSourceFile(node) && typeof node.text === 'string') result.push(node.text);
  if (ts.isPrefixUnaryExpression(node) || ts.isPostfixUnaryExpression(node)) result.push(node.operator);
  ts.forEachChild(node, child => { result.push(tree(child, source)); });
  return result;
}
let compared = 0;
for (const target of ['javascript', 'typescript']) {
  for (const bits of [32, 64]) {
    for (const mode of ['pretty', 'compact']) {
      const project = path.join(directory, target, String(bits), mode);
      await writeFile(path.join(project, 'package.json'), '{"type":"module"}\n');
      await symlink(dependencies, path.join(project, 'node_modules')).catch(error => {
        if (error.code !== 'EEXIST') throw error;
      });
      const strategyPath = 'src/lawspec_data_strategies.' +
        (target === 'typescript' ? 'ts' : 'mjs');
      const strategyContent = target === 'typescript'
        ? '// @ts-nocheck\n' + strategies.replaceAll('.mjs', '.js') : strategies;
      if (mode === 'pretty') {
        await writeFile(path.join(project, strategyPath), strategyContent);
        await writeFile(path.join(directory, target, String(bits), 'compact',
          strategyPath), strategyContent);
      }
      for (const file of await files(path.join(project, 'src'))) {
        const content = await readFile(file, 'utf8');
        const parsed = ts.createSourceFile(file, content, ts.ScriptTarget.ESNext, true,
          target === 'typescript' ? ts.ScriptKind.TS : ts.ScriptKind.JS);
        assert.deepEqual(parsed.parseDiagnostics, [], file);
        if (mode === 'pretty') {
          assert.deepEqual(continuationViolations(ts, parsed), [], file);
          assert.ok(content.split('\n').every(line => line.length <= 80 || /^import /.test(line)), file);
          const compact = await readFile(file.replace(`${path.sep}pretty${path.sep}`,
            `${path.sep}compact${path.sep}`), 'utf8');
          const other = ts.createSourceFile(file, compact, ts.ScriptTarget.ESNext, true,
            target === 'typescript' ? ts.ScriptKind.TS : ts.ScriptKind.JS);
          assert.deepEqual(tree(parsed, parsed), tree(other, other), file);
          compared++;
        }
      }
      if (target === 'typescript') {
        await writeFile(path.join(project, 'tsconfig.json'), JSON.stringify({
          compilerOptions: {target: 'ES2022', module: 'NodeNext', strict: true,
            rootDir: 'src', outDir: 'dist', skipLibCheck: true}, include: ['src/**/*.ts'],
        }));
        execFileSync(process.execPath, [tsc, '-p', project], {stdio: 'inherit'});
      }
      const env = {...process.env,
        LAWSPEC_FAST_CHECK: path.join(dependencies, 'fast-check/lib/fast-check.js'),
        LAWSPEC_DATA_DIR: path.join(project,
        target === 'typescript' ? 'dist' : 'src'), LAWSPEC_MACHINE_BITS: String(bits),
        LAWSPEC_DATA_EXTENSION: target === 'typescript' ? 'js' : 'mjs'};
      const check = path.join(root, 'test/runtime/WebGeneratedConstructorCheck.mjs');
      execFileSync(process.execPath, [check], {env, stdio: 'inherit'});
      const dataFile = path.join(env.LAWSPEC_DATA_DIR,
        `lawspec_data.${env.LAWSPEC_DATA_EXTENSION}`);
      const original = await readFile(dataFile, 'utf8');
      const parsed = ts.createSourceFile(dataFile, original, ts.ScriptTarget.ESNext,
        true, ts.ScriptKind.JS);
      const callbacks = new Map();
      function collect(node) {
        if (ts.isFunctionDeclaration(node) &&
            node.name?.text.startsWith('_lawspec_field_predicate')) {
          callbacks.set(node.name.text, node.body);
        }
        ts.forEachChild(node, collect);
      }
      collect(parsed);
      for (const [name, body] of [
        ['_lawspec_field_predicate0', '{ return true; }'],
        ['_lawspec_field_predicate1', "{ return _fields[0].description === 'same'; }"],
      ]) {
        const node = callbacks.get(name);
        assert.ok(node, `missing callback: ${name}`);
        try {
          await writeFile(dataFile, original.slice(0, node.getStart(parsed)) + body +
            original.slice(node.end));
          const mutant = spawnSync(process.execPath, [check], {env, encoding: 'utf8'});
          const log = (mutant.stdout ?? '') + (mutant.stderr ?? '');
          assert.notEqual(mutant.status, 0, `mutant survived: ${name}`);
          assert.match(log, /Missing expected exception/);
          assert.doesNotMatch(log, /SyntaxError|ReferenceError|ERR_MODULE_NOT_FOUND/);
        } finally {
          await writeFile(dataFile, original);
        }
      }
      console.log(`${target} emitted constructor checks passed: ${bits}/${mode}`);
    }
  }
}
console.log(`${compared} generated artifacts pass layout and AST parity checks`);
