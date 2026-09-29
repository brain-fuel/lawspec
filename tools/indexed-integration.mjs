// Generate and execute the indexed-family example on every installed native target.
// Correct adapters must pass free, fixed and shared index laws with their
// dependent result contracts; every index-breaking mutant must fail at test time.
import {spawn} from 'node:child_process';
import {readFile, mkdir, writeFile, symlink, copyFile, rm, access} from 'node:fs/promises';
import path from 'node:path';
import {indexedAdapter, indexedMutants} from './indexed-adapters.mjs';
import {createCompiler} from '../npm/api.mjs';
import {templates, targets} from '../npm/templates.mjs';

const root = path.resolve(import.meta.dirname, '..');
const compiler = await createCompiler();
const localGradle = path.join(root, '.tools/gradle-9.3.0/bin/gradle');
const gradle = await access(localGradle).then(() => localGradle, () => 'gradle');
const sources = [{
  path: 'indexed_families.lawspec',
  content: await readFile(path.join(root, 'examples/specs/indexed_families.lawspec'), 'utf8'),
}];
const bits = Number(process.env.LAWSPEC_MACHINE_BITS || 64);
const minify = process.env.LAWSPEC_MINIFY === '1';
const selected = process.argv.slice(2).length ? process.argv.slice(2) : targets;
const adapterPattern = /(^|\/)(indexed\.(py|mjs|ts|rs)|Indexed\.(java|kt|hs)|indexed\/adapter\.go)$/;

function run(cmd, args, cwd) {
  return new Promise((resolve, reject) => {
    const child = spawn(cmd, args, {cwd});
    let log = '';
    child.stdout.on('data', (s) => log += s);
    child.stderr.on('data', (s) => log += s);
    child.on('error', reject);
    child.on('exit', (code) => resolve({code, log}));
  });
}

for (const target of selected) {
  const dir = path.join(root, '.artifacts/indexed' + (bits === 32 ? '32' : '') + (minify ? '-compact' : ''), target);
  await mkdir(dir, {recursive: true});
  for (const folder of ['src', 'test', 'tests', 'example']) {
    await rm(path.join(dir, folder), {recursive: true, force: true});
  }
  const result = await compiler.planGeneration({sources, target, machineBits: bits, minify});
  if (result.diagnostics.length) throw new Error(JSON.stringify(result.diagnostics));
  const adapter = result.files.find((f) => f.ownership === 'user' && adapterPattern.test(f.path));
  if (!adapter) throw new Error(`${target}: no indexed adapter was generated`);
  const files = [...Object.entries(templates(target)).map(([p, content]) => ({path: p, content})), ...result.files];
  for (const f of files) {
    const p = path.join(dir, f.path);
    await mkdir(path.dirname(p), {recursive: true});
    await writeFile(p, f === adapter ? indexedAdapter(target) : f.content);
  }
  if (['javascript', 'typescript'].includes(target)) {
    await symlink(path.join(root, '.integration', target, 'node_modules'), path.join(dir, 'node_modules'))
        .catch((e) => { if (e.code !== 'EEXIST') throw e; });
  }
  if (target === 'go') await copyFile(path.join(root, 'test/locks/go/go.sum'), path.join(dir, 'go.sum'));
  const offline = process.env.LAWSPEC_OFFLINE === '1';
  const commands = {
    rust: ['cargo', ['test', ...(offline ? ['--offline'] : [])]],
    java: ['mvn', [...(offline ? ['-o'] : []), '-q', 'test']],
    python: [process.env.LAWSPEC_PYTHON || path.join(root, '.integration/python/.venv/bin/python'), ['-B', '-m', 'pytest', '-q']],
    javascript: ['node', ['--test', ...result.files.filter((f) => f.path.endsWith('.test.mjs')).map((f) => f.path)]],
    typescript: ['npm', ['test']],
    go: ['go', ['test', './...']],
    haskell: ['stack', ['--no-terminal', 'test']],
    kotlin: [gradle, ['test', '--console=plain']],
  };
  const [cmd, args] = commands[target];
  const passing = await run(cmd, args, dir);
  await writeFile(path.join(dir, 'correct.log'), passing.log);
  if (passing.code) throw new Error(`${target}: correct indexed adapters failed (see ${dir}/correct.log)`);
  console.log(`${target}: indexed families pass with fixed, shared and free indices`);
  const adapterPath = path.join(dir, adapter.path);
  try {
    for (const mutant of indexedMutants(target)) {
      await writeFile(adapterPath, mutant.content);
      const report = await run(cmd, target === 'python' ? [...args, '-x'] : args, dir);
      await writeFile(path.join(dir, `mutant-${mutant.name}.log`), report.log);
      if (!report.code) throw new Error(`${target}: mutant ${mutant.name} escaped detection`);
      if (/error\[E\d+\]|could not compile|COMPILATION ERROR|compileKotlin FAILED|compileTestKotlin FAILED|SyntaxError|\[build failed\]|parse error on input|not in scope|error TS\d+/i.test(report.log)) {
        throw new Error(`${target}: mutant ${mutant.name} failed to compile (see log)`);
      }
      console.log(`${target}: rejected ${mutant.name}`);
    }
  } finally {
    await writeFile(adapterPath, indexedAdapter(target));
  }
}
