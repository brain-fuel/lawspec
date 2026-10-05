// The CLI reads package manifests and sends them with the project's sources;
// the compiler checks versions, namespaces and import visibility.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {execFile} from 'node:child_process';
import {cp, mkdtemp, readFile, rm, writeFile} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {promisify} from 'node:util';

const run = promisify(execFile);
const cli = new URL('../bin/lawspec.mjs', import.meta.url).pathname;
const example = new URL('../../examples/packages/', import.meta.url).pathname;

async function copyExample(t) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'lawspec-packages-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  await cp(example, root, {recursive: true});
  return root;
}

async function lawspec(cwd, ...args) {
  try {
    const {stdout} = await run(process.execPath, [cli, ...args, '--json'], {cwd});
    return JSON.parse(stdout);
  } catch (error) {
    return JSON.parse(error.stdout);
  }
}

test('a project checks against a package dependency', async t => {
  const root = await copyExample(t);
  const result = await lawspec(path.join(root, 'orders'), 'check');
  assert.deepEqual(result.diagnostics, []);
  assert.deepEqual(result.packages.map(p => [p.name, p.version, p.units]), [
    ['shop.domain', '1.2.0', ['shop.domain']],
    ['shop.tax', '1.0.0', ['shop.tax.v1x0x0.api', 'shop.tax.v1x0x0.rates']],
    ['shop.tax', '2.0.0', ['shop.tax.v2x0x0.api', 'shop.tax.v2x0x0.rates']],
  ]);
  assert.ok(result.laws.some(l => l.owner === 'shop.orders'));
  assert.ok(result.laws.some(l => l.owner === 'shop.domain'));
});

test('an unsatisfied version range is rejected', async t => {
  const root = await copyExample(t);
  const config = path.join(root, 'orders', 'lawspec.json');
  const settings = JSON.parse(await readFile(config, 'utf8'));
  await writeFile(config, JSON.stringify({...settings, dependencies: {'shop.domain': '^2.0.0'}}));
  const result = await lawspec(path.join(root, 'orders'), 'check');
  assert.match(result.diagnostics[0].message, /requires shop\.domain \^2\.0\.0, but version 1\.2\.0 is supplied/);
});

test('lawspec package summarizes a package', async t => {
  const root = await copyExample(t);
  const summary = await lawspec(root, 'package', '--project', 'shop-domain');
  assert.equal(summary.name, 'shop.domain');
  assert.equal(summary.version, '1.2.0');
  assert.deepEqual(summary.units, ['shop.domain']);
  assert.equal(summary.laws.length, 2);
});

test('a package unit outside its namespace is rejected', async t => {
  const root = await copyExample(t);
  const source = path.join(root, 'shop-domain', 'src', 'domain.lawspec');
  await writeFile(source, (await readFile(source, 'utf8')).replace('unit shop.domain', 'unit elsewhere.domain'));
  const result = await lawspec(root, 'package', '--project', 'shop-domain');
  assert.match(result.diagnostics[0].message, /must be named shop\.domain or shop\.domain\.<name>/);
});
