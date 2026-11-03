import assert from 'node:assert/strict';
import {test} from 'node:test';
import {readFile} from 'node:fs/promises';
import {spawnSync} from 'node:child_process';
import {createCompiler} from '../api.mjs';
import {proveWithZ3} from '../proof.mjs';

const compiler = await createCompiler();
const sources = await Promise.all(
  ['record', 'pair', 'nested'].map(async shape => ({
    path: `induction-product-${shape}.lawspec`,
    content: await readFile(
      new URL(
        `../../test/fixtures/induction-product-${shape}.lawspec`,
        import.meta.url,
      ),
      'utf8',
    ),
  })),
);
const request = {
  schemaVersion: 5,
  languageProfile: '1.0-rc.2',
  verification: {layers: ['proof']},
  sources,
};
const z3 =
  process.env.LAWSPEC_Z3 ??
  (spawnSync('z3', ['-version']).status === 0 ? 'z3' : null);

test('record, Pair and nested product payloads have structural induction cases', async () =>
{
  const result = await compiler.proofTasks(request);
  assert.deepEqual(result.diagnostics, []);
  assert.equal(result.proofTasks.length, 9);
  for (const task of result.proofTasks)
  {
    assert.equal(task.status, 'ready', task.reason);
    assert.equal(task.induction.status, 'ready', task.induction.reason);
    assert.equal(task.induction.cases.length, 2);
  }
});

test(
  'real Z3 proves product-payload composition and evaluator-confirms false idempotence',
  {skip: z3 ? false : 'install Z3 or set LAWSPEC_Z3 for solver integration'},
  async () =>
  {
    const result = await proveWithZ3(compiler, request, {
      binary: z3,
      timeoutMs: 5000,
      memoryMb: 256,
    });
    assert.deepEqual(result.diagnostics, []);
    const falseLaws = result.solverEvidence.filter(row =>
      row.declaration.endsWith('::law::falseIdempotence'),
    );
    assert.equal(falseLaws.length, 3);
    for (const shape of ['record', 'pair', 'nested'])
    {
      const row = name =>
        result.solverEvidence.find(
          item => item.declaration === `induction.${shape}::law::${name}`,
        );
      for (const name of ['associative', 'leftIdentity'])
      {
        assert.equal(
          row(name).status,
          'proved',
          `${shape}/${name}: ${row(name).reason}`,
        );
        assert.ok(
          row(name).induction.cases.every(item => item.outcome === 'unsat'),
        );
      }
      const falseLaw = row('falseIdempotence');
      assert.equal(falseLaw.status, 'refuted', falseLaw.reason);
      assert.equal(falseLaw.modelValidated, true);
      assert.ok(falseLaw.counterexample.inputs.length > 0);
    }
  },
);
