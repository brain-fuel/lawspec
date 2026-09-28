import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import {readFile, readdir, writeFile, symlink} from 'node:fs/promises';
import {createRequire} from 'node:module';
import {createHash} from 'node:crypto';
import path from 'node:path';
import {continuationViolations} from './web-continuations.mjs';

const root = path.resolve(import.meta.dirname, '..');
const fixture = process.env.LAWSPEC_PAYLOAD_FIXTURE;
assert.ok(fixture, 'Set LAWSPEC_PAYLOAD_FIXTURE');
const require = createRequire(import.meta.url);
const ts = require(path.join(root, '.artifacts/web-data-deps/typescript/lib/typescript.js'));
const tsc = path.join(root, '.artifacts/web-data-deps/typescript/bin/tsc');
const dependencies = path.join(root, '.artifacts/lists/javascript/node_modules');

async function sources(directory) {
  const result = new Map();
  for (const relative of ['src', 'test']) {
    async function walk(dir) {
      for (const entry of await readdir(dir, {withFileTypes: true})) {
        const file = path.join(dir, entry.name);
        if (entry.isDirectory()) await walk(file);
        else if (/\.(mjs|ts)$/.test(entry.name)) result.set(
          path.relative(directory, file), await readFile(file, 'utf8'));
      }
    }
    await walk(path.join(directory, relative));
  }
  return result;
}
function audit(name, content, readable) {
  const parsed = ts.createSourceFile(name, content, ts.ScriptTarget.ESNext, true,
    name.endsWith('.ts') ? ts.ScriptKind.TS : ts.ScriptKind.JS);
  assert.deepEqual(parsed.parseDiagnostics, []);
  if (readable) {
    assert.deepEqual(continuationViolations(ts, parsed), [], name);
    for (const line of content.split('\n')) {
      assert.ok([...line].length <= 80, `${name}: ${line}`);
      assert.doesNotMatch(line, /[ \t]+$/);
    }
  }
  const hash = createHash('sha256');
  function visit(node) {
    if (ts.isParenthesizedExpression(node)) return visit(node.expression);
    hash.update(`${node.kind}:${node.flags & ts.NodeFlags.BlockScoped}:`);
    if (ts.isPrefixUnaryExpression(node) || ts.isPostfixUnaryExpression(node)) hash.update(`${node.operator}:`);
    if (typeof node.text === 'string' && !ts.isSourceFile(node)) hash.update(JSON.stringify(node.text));
    ts.forEachChild(node, visit);
    hash.update(';');
  }
  visit(parsed);
  return hash.digest('hex');
}
for (const target of ['javascript', 'typescript']) {
  for (const bits of [32, 64]) {
    for (const builtins of [false, true]) {
      const modes = [];
      for (const compact of [false, true]) {
        const directory = path.join(root, `.artifacts/web-payload-emission/${target}-${bits}-${compact}-${builtins}`);
        execFileSync(fixture, [String(bits), compact ? 'True' : 'False', directory,
          target, ...(builtins ? ['builtins'] : [])]);
        await writeFile(path.join(directory, 'package.json'), '{"type":"module"}\n');
        await symlink(dependencies, path.join(directory, 'node_modules')).catch(error => {
          if (error.code !== 'EEXIST') throw error;
        });
        modes.push(await sources(directory));
        const typed = target === 'typescript';
        if (typed) {
          await writeFile(path.join(directory, 'tsconfig.json'), JSON.stringify({
            compilerOptions: {target: 'ES2022', module: 'NodeNext', strict: true,
              rootDir: '.', outDir: 'dist', skipLibCheck: true},
            include: ['src/**/*.ts', 'test/**/*.ts'],
          }));
          execFileSync(process.execPath, [tsc, '-p', directory], {stdio: 'pipe'});
        }
        const output = path.join(directory, typed ? 'dist' : '');
        const ext = typed ? 'js' : 'mjs';
        if (!builtins) {
          const check = `
import assert from 'node:assert/strict';
import * as data from './src/lawspec_data.${ext}';
import * as payload from './src/lawspec_definitions/payload.${ext}';
const symbols = new Map();
const value = new data.TreeNode([new data.TreeLeaf(2, -128), new data.TreeLeaf(3, 0)]);
assert.equal(payload.above(symbols, value, 1), true);
assert.equal(payload.above(symbols, value, 2), false);
assert.equal(payload.positive(symbols, []), true);
assert.equal(payload.positive(symbols, [1, 2]), true);
assert.equal(payload.positive(symbols, [1, 0]), false);
assert.ok(payload.identity(symbols, new data.PackPack(value)) instanceof data.PackPack);
assert.throws(() => payload.identity(symbols, new data.PackPack(new data.TreeLeaf(0, 0))), /field refinement/);
`;
          execFileSync(process.execPath, ['--input-type=module', '-e', check], {cwd: output, stdio: 'pipe'});
        }
        const test = path.join(output, `test/payload.lawspec.test.${ext}`);
        const testSource = await readFile(test, 'utf8');
        assert.match(testSource, /allPayloads/);
        assert.match(testSource, /fc\.assert/);
        execFileSync(process.execPath, ['--test', test], {cwd: output, stdio: 'pipe', timeout: 60000});
      }
      assert.deepEqual([...modes[0].keys()].sort(), [...modes[1].keys()].sort());
      for (const [name, content] of modes[0]) assert.equal(
        audit(name, content, true), audit(name, modes[1].get(name), false), name);
    }
  }
}
console.log('JS/TS payload definitions, constructors and properties pass 16 width/layout/domain configurations, strict tsc, style and AST parity');
