// Generated from templates/npm/test/evaluation-categories.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile, mkdtemp, mkdir, writeFile, rm} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {createCompiler} from '../api.mjs';
import {templates} from '../templates.mjs';

const compiler = await createCompiler();
const fixture = name =>
  readFile(new URL(`../../test/fixtures/${name}`, import.meta.url), 'utf8');
const base = {
  schemaVersion: 5,
  languageProfile: '1.0-rc.2',
  verification: {layers: ['exhaustive', 'property']},
};

test('stateful attempt laws defer; pure false laws still refute', async () =>
{
  const content = await fixture('effectful-attempt.lawspec');
  const result = await compiler.check({
    ...base,
    sources: [{path: 'sink.lawspec', content}],
  });
  assert.deepEqual(result.diagnostics, []);
  const law = result.evidence.find(row =>
    row.declaration.endsWith('::law::queued'),
  );
  assert.equal(law.status, 'planned');
  assert.doesNotMatch(
    JSON.stringify(result),
    /SourceSpan|a failure is caught when/,
  );
  const handler = result.units.find(unit => unit.id === 'evaluation.sink')
    .handlers[0];
  assert.equal(handler.goEmbedding.available, false);
  assert.ok(handler.goEmbedding.reasons.length > 0);
  assert.equal(handler.goEmbedding.runtime, 'checked-dynamic');
  const helper = content
    .replace(
      'law queued using memorySink',
      'procedure recordAccepted (event :: Int32) -> Bool uses Sink is prelude.isRight (prelude.attempt (record event)) end procedure\nlaw queued using memorySink',
    )
    .replace(
      'prelude.isRight (prelude.attempt (record 1)) implies',
      'recordAccepted 1 implies',
    );
  const indirect = await compiler.check({
    ...base,
    sources: [{path: 'helper.lawspec', content: helper}],
  });
  assert.deepEqual(indirect.diagnostics, []);
  assert.equal(
    indirect.evidence.find(row => row.declaration.endsWith('::law::queued'))
      .status,
    'planned',
  );
  assert.doesNotMatch(
    JSON.stringify(indirect),
    /SourceSpan|a failure is caught when/,
  );
  const falseResult = await compiler.check({
    ...base,
    sources: [
      {
        path: 'false.lawspec',
        content:
          'unit control\nlaw selected is definition: false end definition end law\nend unit',
      },
    ],
  });
  assert.ok(falseResult.diagnostics.length > 0);
  assert.ok(falseResult.evidence.some(row => row.status === 'refuted'));
});

test('public signatures retain dependent indices and linear transitions', async () =>
{
  const content = await readFile(
    new URL('../examples/specs/models.lawspec', import.meta.url),
    'utf8',
  );
  const result = await compiler.check({
    ...base,
    verification: {layers: []},
    sources: [{path: 'models.lawspec', content}],
  });
  assert.deepEqual(result.diagnostics, []);
  const declarations = result.units.find(
    unit => unit.id === 'example.models',
  ).declarations;
  assert.match(
    declarations.find(item => item.name === 'empty').typeText,
    /Stack 0/,
  );
  assert.match(
    declarations.find(item => item.name === 'push').typeText,
    /Stack n \/ Stack \(n \+ 1\)/,
  );
});

test('Go compact layout preserves fixed text while compacting wide declarations', async () =>
{
  const args = Array.from(
    {length: 20},
    (_, index) => `(argument${index} :: Int32)`,
  ).join(' ');
  const request = {
    ...base,
    target: 'go',
    sources: [
      {
        path: 'wide.lawspec',
        content: `unit wide\nfunction selected ${args} -> Int32 is argument0 end function\nend unit`,
      },
    ],
  };
  const readable = await compiler.planGeneration(request);
  const compact = await compiler.planGeneration({...request, minify: true});
  assert.deepEqual(readable.diagnostics, []);
  assert.deepEqual(compact.diagnostics, []);
  const file = result =>
    result.files.find(item => item.path.endsWith('lawspec_definitions.go'))
      .content;
  assert.ok(file(compact).length < file(readable).length);
  assert.deepEqual(readable.evidence, compact.evidence);
});

const go = spawnSync('go', ['version']).status === 0;
test(
  'foreign failure bindings compile and unwrap wrapped native errors',
  {skip: go ? false : 'Go toolchain unavailable'},
  async () =>
  {
    const request = JSON.parse(await fixture('go-imported-failures.json'));
    const result = await compiler.planGeneration(request);
    assert.deepEqual(result.diagnostics, []);
    assert.ok(result.evidence.some(row => row.executionKind === 'measurement'));
    const root = await mkdtemp(path.join(tmpdir(), 'lawspec-go-failure-'));
    try
    {
      await mkdir(path.join(root, 'domain'));
      await writeFile(
        path.join(root, 'go.mod'),
        templates('go')['go.mod'].replace(
          /^module .*$/m,
          'module example.com/app',
        ),
      );
      for (const file of result.files)
      {
        await mkdir(path.dirname(path.join(root, file.path)), {
          recursive: true,
        });
        await writeFile(path.join(root, file.path), file.content);
      }
      const domain = `package domain
import "fmt"
type NothingToUndo struct{ Message string }
func (e NothingToUndo) Error() string { return e.Message }
func UndoLast(values []int32) { panic(fmt.Errorf("wrapped: %w", NothingToUndo{Message: "empty page"})) }
func Fast(_ struct{}) {}
`;
      await writeFile(path.join(root, 'domain', 'domain.go'), domain);
      const run = spawnSync('go', ['test', '-mod=mod', './...'], {
        cwd: root,
        encoding: 'utf8',
        timeout: 120000,
      });
      assert.equal(run.status, 0, run.stdout + run.stderr);
      await writeFile(
        path.join(root, 'domain', 'domain.go'),
        domain.replace(
          'NothingToUndo{Message: "empty page"}',
          'fmt.Errorf("unrelated error")',
        ),
      );
      const wrong = spawnSync('go', ['test', '-mod=mod', './issue/undo'], {
        cwd: root,
        encoding: 'utf8',
        timeout: 120000,
      });
      assert.notEqual(
        wrong.status,
        0,
        'an unrelated native error must not satisfy the declared failure',
      );
      assert.doesNotMatch(
        wrong.stdout + wrong.stderr,
        /undefined:|build failed/i,
      );
    }
    finally
    {
      await rm(root, {recursive: true, force: true});
    }
  },
);

test('Go validates foreign references consistently across binding categories', async () =>
{
  const request = JSON.parse(await fixture('go-imported-failures.json'));
  for (const native of [
    ['missing', 'NothingToUndo'],
    ['domain', 'privateError'],
    ['domain', 'type'],
  ])
  {
    const result = await compiler.planGeneration({
      ...request,
      nativeBindings: {
        ...request.nativeBindings,
        failures: [{...request.nativeBindings.failures[0], native}],
      },
    });
    assert.ok(
      result.diagnostics.some(row => row.code === 'native-binding'),
      JSON.stringify(result.diagnostics),
    );
    assert.equal(result.files?.length ?? 0, 0);
  }
});

test(
  'Go foreign handler factories compile without adapter function bindings',
  {skip: go ? false : 'Go toolchain unavailable'},
  async () =>
  {
    const content = (await fixture('effectful-attempt.lawspec')).replace(
      'law queued using memorySink',
      'law queued',
    );
    const result = await compiler.planGeneration({
      ...base,
      target: 'go',
      sources: [{path: 'sink.lawspec', content}],
      nativeBindings: {
        goImports: [{alias: 'domain', path: 'example.com/app/domain'}],
        handlers: [
          {ability: 'evaluation.sink::Sink', native: ['domain', 'NewSink']},
        ],
      },
    });
    assert.deepEqual(result.diagnostics, []);
    assert.ok(result.warnings.some(row => row.code === 'go-handler-embedding'));
    const root = await mkdtemp(path.join(tmpdir(), 'lawspec-go-handler-'));
    try
    {
      await mkdir(path.join(root, 'domain'));
      await writeFile(
        path.join(root, 'go.mod'),
        templates('go')['go.mod'].replace(
          /^module .*$/m,
          'module example.com/app',
        ),
      );
      for (const file of result.files)
      {
        await mkdir(path.dirname(path.join(root, file.path)), {
          recursive: true,
        });
        await writeFile(path.join(root, file.path), file.content);
      }
      await writeFile(
        path.join(root, 'domain', 'domain.go'),
        `package domain
 type Sink struct { queued int64 }
 func NewSink() *Sink { return &Sink{} }
 func (sink *Sink) Record(event int32) { sink.queued++ }
 func (sink *Sink) Pending() int64 { return sink.queued }
 `,
      );
      const run = spawnSync('go', ['test', '-mod=mod', './...'], {
        cwd: root,
        encoding: 'utf8',
        timeout: 120000,
      });
      assert.equal(run.status, 0, run.stdout + run.stderr);
    }
    finally
    {
      await rm(root, {recursive: true, force: true});
    }
  },
);

test(
  'Go CLI budget execution is reported as measured with scoped durations',
  {skip: go ? false : 'Go toolchain unavailable'},
  async () =>
  {
    const {configEDN} = await import('./manifest-fixtures.mjs');
    const request = JSON.parse(await fixture('go-imported-failures.json'));
    const root = await mkdtemp(path.join(tmpdir(), 'lawspec-go-budget-'));
    const cli = new URL('../bin/lawspec.mjs', import.meta.url).pathname;
    const run = (...args) =>
      spawnSync(process.execPath, [cli, ...args], {
        cwd: root,
        encoding: 'utf8',
        timeout: 120000,
        env: {...process.env, GOFLAGS: '-mod=mod'},
      });
    try
    {
      await mkdir(path.join(root, 'laws'));
      await mkdir(path.join(root, 'domain'));
      await writeFile(
        path.join(root, 'go.mod'),
        templates('go')['go.mod'].replace(
          /^module .*$/m,
          'module example.com/app',
        ),
      );
      await writeFile(
        path.join(root, 'laws', 'undo.lawspec'),
        request.sources[0].content,
      );
      await writeFile(
        path.join(root, 'domain', 'domain.go'),
        `package domain
 type NothingToUndo struct{ Message string }
 func (failure NothingToUndo) Error() string { return failure.Message }
 func UndoLast(values []int32) { panic(NothingToUndo{Message: "empty page"}) }
 func Fast(_ struct{}) {}
 `,
      );
      await writeFile(
        path.join(root, 'lawspec.edn'),
        configEDN({
          manifestVersion: 1,
          languageProfile: '1.0-rc.2',
          verification: {layers: ['property']},
          sources: ['laws'],
          targets: [
            {language: 'go', root: '.', nativeBindings: request.nativeBindings},
          ],
        }),
      );
      const dependencies = spawnSync(
        'go',
        ['mod', 'download', 'pgregory.net/rapid'],
        {
          cwd: root,
          encoding: 'utf8',
          timeout: 120000,
        },
      );
      assert.equal(
        dependencies.status,
        0,
        dependencies.stdout + dependencies.stderr,
      );
      const generated = run('generate', '--target', 'go', '--json');
      assert.equal(generated.status, 0, generated.stdout + generated.stderr);
      const tested = run('test', '--target', 'go', '--json');
      assert.equal(tested.status, 0, tested.stdout + tested.stderr);
      const reported = run('evidence', '--json');
      assert.equal(reported.status, 0, reported.stdout + reported.stderr);
      const result = JSON.parse(reported.stdout);
      const budget = result.find(
        row => row.declaration === 'issue.undo::law::quick',
      );
      assert.equal(budget.status, 'measured', JSON.stringify(budget));
      assert.equal(budget.nativeEvidence.status, 'passed');
      assert.ok(budget.nativeEvidence.measurements.length > 0);
      assert.ok(
        budget.nativeEvidence.measurements.every(
          item => item.kind === 'native-check-duration' && item.seconds >= 0,
        ),
      );
      assert.match(
        budget.nativeEvidence.measurementScope,
        /including harness overhead/,
      );
      const domainFile = path.join(root, 'domain', 'domain.go');
      const domainSource = await readFile(domainFile, 'utf8');
      await writeFile(
        domainFile,
        domainSource
          .replace('package domain', 'package domain\nimport "time"')
          .replace(
            'func Fast(_ struct{}) {}',
            'func Fast(_ struct{}) { time.Sleep(120 * time.Millisecond) }',
          ),
      );
      const failed = run('test', '--target', 'go', '--json');
      assert.equal(failed.status, 1, failed.stdout + failed.stderr);
      const failedReport = run('evidence', '--json');
      const failedBudget = JSON.parse(failedReport.stdout).find(
        row => row.declaration === 'issue.undo::law::quick',
      );
      assert.equal(failedBudget.status, 'incomplete');
      assert.equal(failedBudget.nativeEvidence.status, 'failed');
    }
    finally
    {
      await rm(root, {recursive: true, force: true});
    }
  },
);
