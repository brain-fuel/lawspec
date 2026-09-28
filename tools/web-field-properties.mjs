import assert from 'node:assert/strict';
import {execFileSync, spawnSync} from 'node:child_process';
import {mkdir, readFile, writeFile, symlink} from 'node:fs/promises';
import {createRequire} from 'node:module';
import path from 'node:path';
import {continuationViolations} from './web-continuations.mjs';

const root = path.resolve(import.meta.dirname, '..');
const compiler = process.env.LAWSPEC_CORE;
assert.ok(compiler, 'Set LAWSPEC_CORE');
const source = await readFile(path.join(root, 'test/fixtures/constructor_properties.lawspec'), 'utf8');
const dependencies = path.join(root, '.artifacts/lists/javascript/node_modules');
const tsc = path.join(root, '.artifacts/web-data-deps/typescript/bin/tsc');
const require = createRequire(import.meta.url);
const ts = require(path.join(root, '.artifacts/web-data-deps/typescript/lib/typescript.js'));
function tree(node) {
  if (ts.isParenthesizedExpression(node)) return tree(node.expression);
  const result = [node.kind, node.flags & ts.NodeFlags.BlockScoped];
  if (!ts.isSourceFile(node) && typeof node.text === 'string') result.push(node.text);
  if (ts.isPrefixUnaryExpression(node) || ts.isPostfixUnaryExpression(node)) result.push(node.operator);
  ts.forEachChild(node, child => { result.push(tree(child)); });
  return result;
}
let compared = 0;
for (const target of ['javascript', 'typescript']) {
  const typescript = target === 'typescript';
  for (const machineBits of [32, 64]) {
    const sourceDir = machineBits === 32 ? 'library/native' : 'src';
    const testDir = machineBits === 32 ? 'checks/properties' : 'test';
    const readable = new Map();
    for (const minify of [false, true]) {
      const request = content => JSON.parse(execFileSync(compiler, [], {
        input: JSON.stringify({method: 'planGeneration', target, machineBits, minify,
          sourceDir, testDir, sources: [{path: 'fields.lawspec', content}]}),
        encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
      }));
      const result = request(source);
      assert.deepEqual(result.diagnostics, []);
      const directory = path.join(root, '.artifacts/web-field-properties', target,
        `${machineBits}-${minify ? 'compact' : 'pretty'}`);
      let adapterPath;
      let adapterSource;
      const testPaths = [];
      for (const file of result.files) {
        const parsed = ts.createSourceFile(file.path, file.content, ts.ScriptTarget.ESNext,
          true, typescript ? ts.ScriptKind.TS : ts.ScriptKind.JS);
        assert.deepEqual(parsed.parseDiagnostics, [], file.path);
        if (!minify) {
          assert.deepEqual(continuationViolations(ts, parsed), [], file.path);
          assert.ok(file.content.split('\n').every(line => line.length <= 80 ||
            /^import |^\/\/ /.test(line)), file.path);
          readable.set(file.path, tree(parsed));
        } else {
          assert.deepEqual(tree(parsed), readable.get(file.path), file.path);
          compared++;
        }
        const destination = path.join(directory, file.path);
        await mkdir(path.dirname(destination), {recursive: true});
        let content = file.content;
        if (file.ownership === 'user' && content.includes('echoAdapter')) {
          content = content.replace(/throw new Error\((["'])echoAdapter\1\);/, 'return value0;');
          assert.notEqual(content, file.content);
          adapterPath = destination;
          adapterSource = content;
        }
        if (file.path.includes('.lawspec.test.')) {
          testPaths.push(path.join(typescript ? 'dist' : '', file.path.replace(/\.ts$/, '.js')));
        }
        await writeFile(destination, content);
      }
      await writeFile(path.join(directory, 'package.json'), '{"type":"module"}\n');
      await symlink(dependencies, path.join(directory, 'node_modules')).catch(error => {
        if (error.code !== 'EEXIST') throw error;
      });
      if (typescript) {
        await writeFile(path.join(directory, 'tsconfig.json'), JSON.stringify({
          compilerOptions: {target: 'ES2022', module: 'NodeNext', strict: true,
            rootDir: '.', outDir: 'dist', skipLibCheck: true},
          include: [`${sourceDir}/**/*.ts`, `${testDir}/**/*.ts`],
        }));
      }
      async function run(label, pattern) {
        if (typescript) execFileSync(process.execPath, [tsc, '-p', directory], {stdio: 'inherit'});
        const check = spawnSync(process.execPath, ['--test',
          ...(pattern ? ['--test-name-pattern', pattern] : []), ...testPaths], {
          cwd: directory, encoding: 'utf8', maxBuffer: 32 * 1024 * 1024,
        });
        const log = (check.stdout ?? '') + (check.stderr ?? '');
        await writeFile(path.join(directory, `${label}.log`), log);
        return {...check, log};
      }
      const correct = await run('correct');
      assert.equal(correct.status, 0, correct.log);
      assert.ok(adapterPath);
      try {
        await writeFile(adapterPath, adapterSource.replace('return value0;',
          "return new data.IdentityIdentity(Symbol('same'));"));
        const mutant = await run('mutant', 'adapter identity.*property');
        assert.notEqual(mutant.status, 0, 'Symbol-description adapter mutant survived');
        assert.match(mutant.log, /field refinement/);
        assert.doesNotMatch(mutant.log, /SyntaxError|ReferenceError|ERR_MODULE_NOT_FOUND/);
      } finally {
        await writeFile(adapterPath, adapterSource);
      }
      const negative = request(source + `
law \`disjunction retains other identities\` is definition is
  \`for all\` (x :: Identity)
    (s :: Symbol where s == symbol("fixture", "same") || s != symbol("fixture", "same")) .
  s = symbol("fixture", "same")
end end
`);
      assert.deepEqual(negative.diagnostics, []);
      const testFile = negative.files.find(file => file.path.includes('.lawspec.test.'));
      const original = result.files.find(file => file.path === testFile.path);
      try {
        await writeFile(path.join(directory, testFile.path), testFile.content);
        const rejected = await run('disjunction', 'disjunction retains other identities.*property');
        assert.notEqual(rejected.status, 0, 'Disjunction narrowed to a singleton');
        assert.match(rejected.log, /expect|Property failed/);
        assert.doesNotMatch(rejected.log, /SyntaxError|ReferenceError|ERR_MODULE_NOT_FOUND/);
      } finally {
        await writeFile(path.join(directory, testFile.path), original.content);
      }
      console.log(`Public ${target} field properties passed: ${machineBits}, minify=${minify}`);
    }
  }
}
console.log(`${compared} public web artifacts pass readable/compact AST parity`);
