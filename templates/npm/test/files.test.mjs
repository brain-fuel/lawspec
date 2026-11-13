import {test} from 'node:test';
import assert from 'node:assert/strict';
import {mkdtemp, readFile, writeFile, rm, symlink} from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import {planWrites, applyWrites, readOptional, digest} from '../files.mjs';
const artifacts = [
  {path: 'src/adapter.py', content: 'user stub\n', ownership: 'user'},
  {path: 'tests/test_law.py', content: 'generated\n', ownership: 'generated'},
];
async function project(t)
{
  const p = await mkdtemp(path.join(os.tmpdir(), 'lawspec-test-'));
  t.after(() => rm(p, {recursive: true, force: true}));
  return p;
}
test('regeneration preserves modified user adapters and is idempotent', async t =>
{
  const p = await project(t);
  await applyWrites([await planWrites(p, artifacts)]);
  await writeFile(path.join(p, 'src/adapter.py'), 'real implementation\n');
  const plan = await planWrites(p, artifacts);
  assert.equal(plan.changes.length, 0);
  assert.equal(
    await readFile(path.join(p, 'src/adapter.py'), 'utf8'),
    'real implementation\n',
  );
});
test('edited generated files and unowned identical files are protected', async t =>
{
  const p = await project(t);
  await applyWrites([await planWrites(p, artifacts)]);
  await writeFile(path.join(p, 'tests/test_law.py'), 'manual edit\n');
  await assert.rejects(planWrites(p, artifacts), /edited/);
  await rm(path.join(p, '.lawspec'), {recursive: true});
  await writeFile(path.join(p, 'tests/test_law.py'), 'generated\n');
  await assert.rejects(planWrites(p, artifacts), /unowned/);
});
test('a mutation run keeps an edited owned file without accepting it', async t =>
{
  const p = await project(t);
  await applyWrites([await planWrites(p, artifacts)]);
  const before = await readFile(
    path.join(p, '.lawspec/generated.json'),
    'utf8',
  );
  const file = path.join(p, 'tests/test_law.py');
  await writeFile(file, 'mutated\n');
  const edited = candidate => candidate === file;
  const plan = await planWrites(p, artifacts, {edited});
  assert.equal(plan.changes.length, 0);
  assert.equal(await readFile(file, 'utf8'), 'mutated\n');
  await applyWrites([plan]);
  assert.equal(
    await readFile(path.join(p, '.lawspec/generated.json'), 'utf8'),
    before,
  );
  // Without the ownership record the file is not the compiler's to leave.
  await rm(path.join(p, '.lawspec'), {recursive: true});
  await assert.rejects(planWrites(p, artifacts, {edited}), /unowned/);
});
test('stale owned tests are removed but user adapters remain', async t =>
{
  const p = await project(t);
  await applyWrites([await planWrites(p, artifacts)]);
  await applyWrites([await planWrites(p, [])]);
  assert.equal(await readOptional(path.join(p, 'tests/test_law.py')), null);
  assert.equal(
    await readFile(path.join(p, 'src/adapter.py'), 'utf8'),
    'user stub\n',
  );
});
test('concurrent edits abort all planned writes', async t =>
{
  const p = await project(t);
  await applyWrites([await planWrites(p, artifacts)]);
  const plan = await planWrites(p, [
    artifacts[0],
    {...artifacts[1], content: 'new generated\n'},
  ]);
  await writeFile(path.join(p, 'tests/test_law.py'), 'concurrent edit\n');
  await assert.rejects(applyWrites([plan]), /changed during generation/);
  assert.equal(
    await readFile(path.join(p, 'tests/test_law.py'), 'utf8'),
    'concurrent edit\n',
  );
});
// A build that never commits generated source cleans the generated
// directories away; generating again must restore exactly what was there,
// and never touch the adapters beside them.
test('a cleaned generated tree is reproduced byte for byte', async t =>
{
  const generated = [
    {
      path: 'src/main/java/example/SuccessorAdapter.java',
      content: 'class SuccessorAdapter {}\n',
      ownership: 'user',
    },
    {
      path: 'target/generated-sources/lawspec/lawspec/runtime/LawSpecRuntime.java',
      content: 'final class LawSpecRuntime {}\r\n// caf\u00e9\n',
      ownership: 'generated',
    },
    {
      path: 'target/generated-test-sources/lawspec/example/SuccessorLawSpecTest.java',
      content: 'class SuccessorLawSpecTest {}\n',
      ownership: 'generated',
    },
    {
      path: 'target/generated-test-sources/lawspec/junit-platform.properties',
      content: 'junit.jupiter.execution.parallel.enabled=true\n',
      ownership: 'generated',
    },
  ];
  const owned = generated.filter(a => a.ownership === 'generated');
  const tree = p => Promise.all(owned.map(a => readFile(path.join(p, a.path))));
  const manifestOf = p =>
    readFile(path.join(p, '.lawspec/generated.json'), 'utf8');
  for (const committed of [true, false])
  {
    const p = await project(t);
    await applyWrites([await planWrites(p, generated)]);
    const adapter = path.join(p, generated[0].path);
    await writeFile(adapter, 'class SuccessorAdapter { /* mine */ }\n');
    const before = await tree(p);
    const manifest = await manifestOf(p);
    // mvn clean, and a checkout that does not commit the ownership record.
    await rm(path.join(p, 'target'), {recursive: true});
    if (!committed) await rm(path.join(p, '.lawspec'), {recursive: true});
    const plan = await planWrites(p, generated);
    assert.deepEqual(
      plan.changes.map(c => [c.action, c.relative]).sort(),
      [
        ...owned.map(a => ['create', a.path]),
        ...(committed ? [] : [['create', '.lawspec/generated.json']]),
      ].sort(),
    );
    assert.deepEqual(plan.preserved, [generated[0].path]);
    await applyWrites([plan]);
    const after = await tree(p);
    for (const [i, bytes] of after.entries())
    {
      assert.ok(bytes.equals(before[i]), owned[i].path);
      assert.equal(
        digest(bytes.toString('utf8')),
        JSON.parse(manifest).files[owned[i].path],
      );
    }
    assert.equal(await manifestOf(p), manifest);
    assert.equal(
      await readFile(adapter, 'utf8'),
      'class SuccessorAdapter { /* mine */ }\n',
    );
    assert.equal((await planWrites(p, generated)).changes.length, 0);
  }
});
test('path traversal and symlink output paths are refused', async t =>
{
  const p = await project(t);
  const outside = await project(t);
  await assert.rejects(
    planWrites(p, [{...artifacts[0], path: '../outside.py'}]),
    /Unsafe/,
  );
  await symlink(outside, path.join(p, 'src'));
  await assert.rejects(planWrites(p, artifacts), /symbolic-link/);
});

test('missing and non-directory output roots have actionable diagnostics', async t =>
{
  const root = await project(t);
  const absent = path.join(root, 'missing', 'target');
  await assert.rejects(
    planWrites(absent, artifacts),
    error =>
      error.message.includes(`Output root does not exist: ${absent}`) &&
      error.message.includes('initialize the target') &&
      !error.message.includes('ENOENT'),
  );
  const file = path.join(root, 'file');
  await writeFile(file, 'keep this file\n');
  await assert.rejects(
    planWrites(file, artifacts),
    /Output root is not a directory/,
  );
  assert.equal(await readFile(file, 'utf8'), 'keep this file\n');
});
