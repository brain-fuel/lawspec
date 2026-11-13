// Generated from templates/npm/test/mutate.test.mjs by lawspec-dev generate. Do not edit.
import {test} from 'node:test';
import assert from 'node:assert/strict';
import {
  mkdtemp,
  mkdir,
  writeFile,
  readFile,
  readdir,
  rm,
} from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {
  parseMutant,
  applyMutant,
  classifyMutation,
  mutateProject,
} from '../mutate.mjs';
import {configEDN} from './manifest-fixtures.mjs';

const source =
  'expect: broken\nexpect-any: law one | law two\n@@ app.txt\n<<<<<<<\ngood\n=======\nbad\n>>>>>>>\n';
test('acceptance mutation format, strict edits and failure classifications', async t =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'mutation-edit-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  const mutant = parseMutant(source);
  assert.deepEqual(mutant.expectations, [['broken'], ['law one', 'law two']]);
  assert.deepEqual(mutant.forbidden, []);
  assert.deepEqual(parseMutant('forbid: secret\n' + source).forbidden, [
    'secret',
  ]);
  await writeFile(path.join(root, 'app.txt'), 'good\n');
  await applyMutant(root, mutant);
  assert.equal(await readFile(path.join(root, 'app.txt'), 'utf8'), 'bad\n');
  await assert.rejects(applyMutant(root, mutant), /exactly once/);
  assert.throws(() => parseMutant('expect: missing'), /no edits/);
  assert.throws(
    () => parseMutant(source.replace('=======', 'damaged')),
    /missing =======/,
  );
  const cases = [
    [{code: 0}, 'surviving'],
    [{code: 1, timedOut: true}, 'timed-out'],
    [{code: 1, report: {diagnostics: [{code: 'unsupported'}]}}, 'unsupported'],
    [
      {code: 1, report: {diagnostics: [{code: 'target-unsupported'}]}},
      'unsupported',
    ],
    [{code: 1, report: {diagnostics: [{code: 'parse'}]}}, 'invalid'],
    [
      {code: 1, report: [{failedLaws: ['unit::one']}], output: 'wrong'},
      'errored',
    ],
    [
      {
        code: 1,
        report: [{failedLaws: ['unit::one']}],
        output: 'broken law two',
      },
      'killed',
    ],
  ];
  for (const [run, status] of cases)
    assert.equal(classifyMutation(run, mutant).status, status);
  // A forbidden text in the output keeps an otherwise killed mutant open.
  assert.equal(
    classifyMutation(
      {
        code: 1,
        report: [{failedLaws: ['unit::one']}],
        output: 'broken law two',
      },
      {...mutant, forbidden: ['law two']},
    ).status,
    'errored',
  );
});

test('passing baseline, kill matrix and workspace preservation use independent copies', async t =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'mutation-project-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  await writeFile(
    path.join(root, 'lawspec.edn'),
    configEDN({
      manifestVersion: 1,
      languageProfile: '1.0-rc.2',
      sources: [],
      targets: [],
    }),
  );
  await mkdir(path.join(root, 'mutants'));
  await writeFile(path.join(root, 'mutants', 'one.mutant'), source);
  await writeFile(path.join(root, 'app.txt'), 'good');
  await mkdir(path.join(root, '.lawspec'));
  await writeFile(path.join(root, '.lawspec/generated.json'), 'ownership');
  const visited = [];
  const report = await mutateProject({
    root,
    run: async copy =>
    {
      assert.notEqual(copy, root);
      assert.equal(
        await readFile(path.join(copy, '.lawspec/generated.json'), 'utf8'),
        'ownership',
      );
      visited.push(await readFile(path.join(copy, 'app.txt'), 'utf8'));
      return visited.length === 1
        ? {code: 0, report: [{ok: true, ran: ['unit::one']}]}
        : {
            code: 1,
            report: [{ok: false, failedLaws: ['unit::one']}],
            output: 'broken law one',
          };
    },
  });
  assert.equal(report.ok, true);
  assert.deepEqual(visited, ['good', 'bad']);
  assert.deepEqual(report.uniqueKills, {'unit::one': ['mutants/one.mutant']});
  assert.equal(await readFile(path.join(root, 'app.txt'), 'utf8'), 'good');
  let count = 0;
  const failed = await mutateProject({
    root,
    run: async () =>
    {
      count++;
      return {code: 1};
    },
  });
  assert.equal(count, 1);
  assert.equal(failed.mutations.length, 0);
});

test('copies share the compiler cache and name the generated files a mutant edits', async t =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'mutation-cache-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  await writeFile(
    path.join(root, 'lawspec.edn'),
    configEDN({
      manifestVersion: 1,
      languageProfile: '1.0-rc.2',
      sources: [],
      targets: [{language: 'python', root: 'out'}],
    }),
  );
  await mkdir(path.join(root, 'mutants'));
  await mkdir(path.join(root, 'out', '.lawspec'), {recursive: true});
  await mkdir(path.join(root, '.lawspec', 'cache', 'build'), {recursive: true});
  await mkdir(path.join(root, '.lawspec', 'results'), {recursive: true});
  await writeFile(path.join(root, '.lawspec/cache/build/seeded'), 'seed');
  await writeFile(path.join(root, '.lawspec/results/passed'), 'stale');
  await writeFile(path.join(root, 'out/generated.py'), 'good');
  await writeFile(path.join(root, 'out/adapter.py'), 'good');
  await writeFile(
    path.join(root, 'out/.lawspec/generated.json'),
    JSON.stringify({version: 1, files: {'generated.py': 'digest'}}),
  );
  for (const name of ['adapter', 'generated'])
    await writeFile(
      path.join(root, 'mutants', `${name}.mutant`),
      `@@ out/${name}.py\n<<<<<<<\ngood\n=======\nbad\n>>>>>>>\n`,
    );
  const runs = [];
  const report = await mutateProject({
    root,
    run: async (copy, args) =>
    {
      const cache = path.join(copy, '.lawspec/cache/build');
      runs.push({
        args,
        cached: (await readdir(cache)).sort(),
        results: await readdir(path.join(copy, '.lawspec')),
      });
      await writeFile(path.join(cache, `run${runs.length}`), '');
      return runs.length === 1
        ? {code: 0, report: [{ok: true, ran: ['unit::one']}]}
        : {code: 1, report: [{ok: false, failedLaws: ['unit::one']}]};
    },
  });
  assert.equal(report.ok, true);
  assert.deepEqual(
    runs.map(row => row.cached),
    [['seeded'], ['run1', 'seeded'], ['run1', 'run2', 'seeded']],
  );
  assert(runs.every(row => !row.results.includes('results')));
  const named = runs.map(row =>
  {
    const index = row.args.indexOf('--mutated-generated');
    return index < 0 ? null : row.args[index + 1];
  });
  assert.deepEqual(named, [null, null, path.join('out', 'generated.py')]);
  assert.deepEqual(await readdir(path.join(root, '.lawspec/cache/build')), [
    'seeded',
  ]);
});

test('invalid edits never execute and other failures retain distinct outcomes', async t =>
{
  const root = await mkdtemp(path.join(os.tmpdir(), 'mutation-outcomes-'));
  t.after(() => rm(root, {recursive: true, force: true}));
  await writeFile(
    path.join(root, 'lawspec.edn'),
    configEDN({
      manifestVersion: 1,
      languageProfile: '1.0-rc.2',
      sources: [],
      targets: [],
    }),
  );
  await mkdir(path.join(root, 'mutants'));
  await writeFile(path.join(root, 'app.txt'), 'good');
  for (const name of [
    'invalid',
    'surviving',
    'errored',
    'timed-out',
    'unsupported',
  ])
    await writeFile(
      path.join(root, 'mutants', `${name}.mutant`),
      `@@ app.txt\n<<<<<<<\n${name === 'invalid' ? 'missing' : 'good'}\n=======\n${name}\n>>>>>>>\n`,
    );
  const visited = [];
  const result = await mutateProject({
    root,
    run: async copy =>
    {
      const value = await readFile(path.join(copy, 'app.txt'), 'utf8');
      visited.push(value);
      if (value === 'good')
        return {code: 0, report: [{ok: true, ran: ['law']}]};
      if (value === 'surviving') return {code: 0};
      if (value === 'timed-out') return {code: 1, timedOut: true};
      if (value === 'unsupported')
        return {code: 1, report: {diagnostics: [{code: 'unsupported'}]}};
      return {code: 1, report: [{ok: false}], output: 'tool failed'};
    },
  });
  assert.deepEqual(
    result.mutations.map(row => row.status),
    ['errored', 'invalid', 'surviving', 'timed-out', 'unsupported'],
  );
  assert.equal(visited.length, 5);
  assert.equal(await readFile(path.join(root, 'app.txt'), 'utf8'), 'good');
  assert.deepEqual(result.killMatrix, {});
});

test('public parsing accepts the repository acceptance mutation corpus', async t =>
{
  const directory = new URL('../../acceptance/', import.meta.url);
  let files;
  try
  {
    files = await readdir(directory, {recursive: true});
  }
  catch (error)
  {
    if (error.code === 'ENOENT')
      return t.skip('acceptance sources are not packaged');
    throw error;
  }
  const mutants = files.filter(file => file.endsWith('.mutant'));
  assert.ok(mutants.length > 0);
  for (const file of mutants)
  {
    const content = await readFile(new URL(file, directory), 'utf8');
    assert.doesNotThrow(() => parseMutant(content), file);
  }
});
