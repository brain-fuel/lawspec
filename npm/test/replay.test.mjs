// Generated from templates/npm/test/replay.test.mjs by lawspec-dev generate. Do not edit.
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {
  afterInvocation,
  batchSummaries,
  continueRun,
  ownFailure,
  planBatches,
  ranText,
  recordFailures,
  startBatch,
  verified,
} from '../replay.mjs';

const law = name => ({law: `unit::law::${name}`});
const [a, b, c, d] = ['a', 'b', 'c', 'd'].map(law);
const own = seed => ({
  seed,
  failed: '2026-11-01T00:00:00.000Z',
  cause: ownFailure,
});
const at = '2026-11-12T00:00:00.000Z';

test('only database laws replay, each batch with its recorded seed, before the fresh batch', () =>
{
  const batches = planBatches(
    [a, b, c, d],
    {[b.law]: own(7), [d.law]: own('9'), [c.law]: own(7)},
    {seed: '42'},
  );
  assert.deepEqual(batches, [
    {seed: '7', replay: true, entries: [b, c]},
    {seed: '9', replay: true, entries: [d]},
    {seed: '42', replay: false, entries: [a]},
  ]);
});

test('an explicit seed runs every law in one batch and a database law outside the selection is ignored', () =>
{
  assert.deepEqual(
    planBatches([a, b], {[b.law]: own(7)}, {seed: '5', replay: false}),
    [{seed: '5', replay: false, entries: [a, b]}],
  );
  assert.deepEqual(planBatches([a], {[b.law]: own(7)}, {seed: 5}), [
    {seed: '5', replay: false, entries: [a]},
  ]);
  assert.deepEqual(planBatches([], {[b.law]: own(7)}, {seed: 5}), []);
});

test('a seed larger than a safe integer replays exactly and a malformed one is refused', () =>
{
  const big = '18446744073709551615';
  assert.equal(planBatches([a], {[a.law]: own(big)}, {seed: '1'})[0].seed, big);
  for (const seed of [undefined, null, 'x', -1, 1.5])
    assert.throws(
      () => planBatches([a], {[a.law]: {seed}}, {seed: '1'}),
      /no whole-number seed for unit::law::a/,
    );
});

test('a failed invocation that executed tests stops neither its batch nor the run', () =>
{
  const failing = afterInvocation(startBatch(), {
    ok: false,
    tests: [{status: 'passed'}, {status: 'failed'}],
    lawTests: 2,
  });
  assert.equal(failing.invocationFailed, true);
  assert.equal(failing.continueBatch, true);
  assert.equal(continueRun(failing), true);
  // A runner that exits 0 with a failed test in its report still failed.
  const reported = afterInvocation(startBatch(), {
    ok: true,
    tests: [{status: 'failed'}],
    lawTests: 1,
  });
  assert.equal(reported.invocationFailed, true);
  assert.equal(continueRun(reported), true);
});

test('a failed invocation that executed no test of a law ends its batch, and the run when the batch executed none', () =>
{
  const unstarted = afterInvocation(startBatch(), {
    ok: false,
    tests: [],
    lawTests: 0,
  });
  assert.equal(unstarted.continueBatch, false);
  assert.equal(continueRun(unstarted), false);
  // A test file that does not load is one failed test that belongs to no law.
  const unloaded = afterInvocation(startBatch(), {
    ok: false,
    tests: [{status: 'failed'}],
    lawTests: 0,
  });
  assert.equal(unloaded.continueBatch, false);
  assert.equal(continueRun(unloaded), false);
  // An earlier invocation of the same batch executed tests: later batches run.
  const first = afterInvocation(startBatch(), {
    ok: true,
    tests: [{status: 'passed'}],
    lawTests: 1,
  });
  assert.equal(first.invocationFailed, false);
  const second = afterInvocation(first, {ok: false, tests: [], lawTests: 0});
  assert.equal(second.continueBatch, false);
  assert.equal(continueRun(second), true);
});

test('a passing batch continues, including one whose runner matched no test', () =>
{
  const passing = afterInvocation(startBatch(), {
    ok: true,
    tests: [],
    lawTests: 0,
  });
  assert.equal(passing.invocationFailed, false);
  assert.equal(passing.continueBatch, true);
  assert.equal(continueRun(passing), true);
});

test('only a law whose own tests failed is recorded', () =>
{
  const database = {};
  const recorded = recordFailures(database, [a, b, c, d], {
    passed: new Set([d.law]),
    attempts: {
      [a.law]: {outcome: 'failed', seed: 11, tests: [{status: 'failed'}]},
      // Its tests passed, but its native invocation failed because of a.
      [b.law]: {outcome: 'incomplete', seed: 11, tests: [{status: 'passed'}]},
      [c.law]: {outcome: 'not-run', seed: 11, tests: []},
      [d.law]: {outcome: 'passed', seed: 11, tests: [{status: 'passed'}]},
    },
    at,
  });
  assert.deepEqual(recorded, {
    [a.law]: {seed: 11, failed: at, cause: ownFailure},
  });
  assert.deepEqual(database, {}, 'the database read is not changed');
});

test('a recorded failure leaves when its law passes and keeps its seed until then', () =>
{
  const database = {[a.law]: own(7), [b.law]: own(8), [c.law]: own(9)};
  const recorded = recordFailures(database, [a, b, c], {
    passed: new Set([a.law]),
    attempts: {
      [a.law]: {outcome: 'passed', seed: 7, tests: [{status: 'passed'}]},
      // Started, not completed: the earlier own failure is still the last one.
      [b.law]: {outcome: 'incomplete', seed: 8, tests: [{status: 'passed'}]},
      [c.law]: {outcome: 'not-run', seed: 9, tests: []},
    },
    at,
  });
  assert.deepEqual(recorded, {[b.law]: own(8), [c.law]: own(9)});
});

test('a failure replayed with another seed records the seed that failed now', () =>
{
  const recorded = recordFailures({[a.law]: own(7)}, [a], {
    passed: new Set(),
    attempts: {
      [a.law]: {outcome: 'failed', seed: 99, tests: [{status: 'failed'}]},
    },
    at,
  });
  assert.deepEqual(recorded[a.law], {seed: 99, failed: at, cause: ownFailure});
});

test('an entry of a law outside this run is kept as it is', () =>
{
  const database = {[a.law]: own(7), [b.law]: {seed: 3, failed: 'earlier'}};
  assert.deepEqual(
    recordFailures(database, [], {passed: new Set(), attempts: {}, at}),
    database,
  );
});

test('an entry written by the old rule is unverified: it replays once, then is marked or removed', () =>
{
  // Before 0.34 one failing invocation recorded all four laws with its seed.
  const old = seed => ({seed, failed: '2026-10-01T00:00:00.000Z'});
  const database = {
    [a.law]: old(5),
    [b.law]: old(5),
    [c.law]: old(5),
    [d.law]: old(5),
  };
  assert.ok(Object.values(database).every(entry => !verified(entry)));
  const batches = planBatches([a, b, c, d], database, {seed: '42'});
  assert.deepEqual(batches, [{seed: '5', replay: true, entries: [a, b, c, d]}]);
  const recorded = recordFailures(database, [a, b, c, d], {
    passed: new Set([d.law]),
    attempts: {
      [a.law]: {outcome: 'failed', seed: 5, tests: [{status: 'failed'}]},
      [b.law]: {outcome: 'incomplete', seed: 5, tests: [{status: 'passed'}]},
      // The tool could not start for c: it has not had its replay.
      [c.law]: {outcome: 'incomplete', seed: 5, tests: []},
      [d.law]: {outcome: 'passed', seed: 5, tests: [{status: 'passed'}]},
    },
    at,
  });
  assert.deepEqual(recorded, {
    [a.law]: {seed: 5, failed: at, cause: ownFailure},
    [c.law]: old(5),
  });
  // The next run replays the real failure alone; b runs with the fresh seed.
  assert.deepEqual(
    planBatches([a, b], {[a.law]: recorded[a.law]}, {seed: '43'}),
    [
      {seed: '5', replay: true, entries: [a]},
      {seed: '43', replay: false, entries: [b]},
    ],
  );
});

test('each batch reports its seed, the laws it ran and the laws never started', () =>
{
  const batches = [
    {seed: '7', replay: true, entries: [a]},
    {seed: '42', replay: false, entries: [b, c]},
  ];
  const rows = batchSummaries(batches, {
    [a.law]: {outcome: 'failed'},
    [b.law]: {outcome: 'passed'},
    [c.law]: {outcome: 'not-run'},
  });
  assert.deepEqual(rows, [
    {seed: '7', replay: true, ran: [a.law]},
    {seed: '42', replay: false, ran: [b.law], notRun: [c.law]},
  ]);
  assert.equal(
    ranText(rows),
    'ran 2 law(s): 1 replayed with seed 7, 1 with seed 42',
  );
});

test('the text names the seed a single batch used, which may be a replayed one', () =>
{
  assert.equal(
    ranText([{seed: '7', replay: true, ran: [a.law]}]),
    'ran 1 law(s) with seed 7',
  );
  assert.equal(
    ranText([
      {seed: '7', replay: true, ran: [], notRun: [a.law]},
      {seed: '42', replay: false, ran: [b.law, c.law]},
    ]),
    'ran 2 law(s) with seed 42',
  );
  assert.equal(
    ranText([{seed: '42', replay: false, ran: [], notRun: [a.law]}]),
    'ran 0 law(s)',
  );
});
