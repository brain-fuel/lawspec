// lawspec init names the project it is run in: --name, then a build file
// already there, then the manifest, then the directory. The compiler spells
// the name for each target; these tests cover what the host passes it and
// writes back. ref:DEC-scaffold-project-name
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {spawnSync} from 'node:child_process';
import {mkdtemp, mkdir, readFile, readdir, writeFile, rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import path from 'node:path';

const cli = new URL('../bin/lawspec.mjs', import.meta.url).pathname;

// A project directory of a chosen name, inside a temporary one.
async function project(t, name, files = {})
{
  const parent = await mkdtemp(path.join(tmpdir(), 'lawspec-names-'));
  t.after(() => rm(parent, {recursive: true, force: true}));
  const root = path.join(parent, name);
  await mkdir(root);
  for (const [file, content] of Object.entries(files))
  {
    await mkdir(path.dirname(path.join(root, file)), {recursive: true});
    await writeFile(path.join(root, file), content);
  }
  return root;
}
const text = (root, name) => readFile(path.join(root, name), 'utf8');
const init = (root, ...args) =>
  spawnSync(process.execPath, [cli, 'init', '--no-install', ...args], {
    cwd: root,
    encoding: 'utf8',
    timeout: 60000,
  });
const passed = result =>
  assert.equal(result.status, 0, result.stdout + result.stderr);

test('the directory names a new project, spelled for the target', async t =>
{
  const root = await project(t, 'Billing Service');
  const result = init(root, '--target', 'rust');
  passed(result);
  assert.match(await text(root, 'Cargo.toml'), /^name = "billing-service"$/m);
  assert.match(await text(root, 'lawspec.edn'), /:name "billing-service"/);
  assert.match(
    result.stdout,
    /^Project name: billing-service \(from the directory name\)\.$/m,
  );
});

test('--name and --group name the project instead of the directory', async t =>
{
  const root = await project(t, 'work');
  const result = init(
    root,
    '--target',
    'java',
    '--name',
    'Ledger API',
    '--group',
    'com.acme',
  );
  passed(result);
  const pom = await text(root, 'pom.xml');
  assert.match(pom, /<groupId>com\.acme<\/groupId>\n {2}<artifactId>ledger-api<\/artifactId>/);
  assert.doesNotMatch(pom, /lawspec-example/);
  assert.match(await text(root, 'lawspec.edn'), /:name "ledger-api"/);
  assert.match(result.stdout, /^Project name: com\.acme:ledger-api \(from --name\)\.$/m);
});

test('a second target takes the name the manifest holds', async t =>
{
  const root = await project(t, 'work');
  passed(init(root, '--target', 'python', '--name', 'ledger'));
  const result = init(root, '--target', 'go', '--project', 'service');
  passed(result);
  assert.match(
    await text(root, 'service/go.mod'),
    /^module example\.com\/ledger\n/,
  );
  assert.match(result.stdout, /\(from lawspec\.edn\)/);
});

test('a build file already there names what init adds beside it', async t =>
{
  const pom =
    '<project>\n  <parent><artifactId>parent</artifactId></parent>\n  <artifactId>orders</artifactId>\n</project>\n';
  const root = await project(t, 'checkout', {'pom.xml': pom});
  const result = init(root, '--target', 'typescript');
  passed(result);
  assert.equal(JSON.parse(await text(root, 'package.json')).name, 'orders');
  assert.match(result.stdout, /^Project name: orders \(from pom\.xml\)\.$/m);
  // The build file itself is not rewritten.
  assert.equal(await text(root, 'pom.xml'), pom);
});

test('running init again keeps a named .NET solution and adds no other', async t =>
{
  const root = await project(t, 'work');
  passed(init(root, '--target', 'fsharp', '--name', 'billing'));
  const first = (await readdir(root)).sort();
  assert.ok(first.includes('Billing.slnx'), first.join(' '));
  assert.match(
    await text(root, 'src/Billing.fsproj'),
    /<RootNamespace>Billing<\/RootNamespace>/,
  );
  await rm(path.join(root, 'lawspec.edn'));
  await rm(path.join(root, 'laws'), {recursive: true});
  const again = init(root, '--target', 'fsharp');
  passed(again);
  assert.match(again.stdout, /Existing build files preserved/);
  assert.deepEqual(
    (await readdir(root)).filter(file => file.endsWith('.slnx')),
    ['Billing.slnx'],
  );
});

test('a name no build file can carry is refused before anything is written', async t =>
{
  const root = await project(t, '---');
  const result = init(root, '--target', 'rust');
  assert.equal(result.status, 1);
  assert.match(
    result.stdout + result.stderr,
    /the directory name "---" has no ASCII letter or digit to make a build name from; give the project's name with --name/,
  );
  assert.deepEqual(await readdir(root), []);
  passed(init(root, '--target', 'rust', '--name', 'dashes'));
  assert.match(await text(root, 'Cargo.toml'), /^name = "dashes"$/m);
});

test('--group is refused where the build has none, and both options outside init', async t =>
{
  const root = await project(t, 'work');
  const group = init(root, '--target', 'python', '--group', 'com.acme');
  assert.equal(group.status, 1);
  assert.match(
    group.stdout + group.stderr,
    /--group applies to the java, kotlin, groovy and go targets/,
  );
  assert.deepEqual(await readdir(root), []);
  const check = spawnSync(process.execPath, [cli, 'check', '--name', 'x'], {
    cwd: root,
    encoding: 'utf8',
    timeout: 60000,
  });
  assert.equal(check.status, 1);
  assert.match(check.stdout + check.stderr, /--name and --group apply to init/);
});
