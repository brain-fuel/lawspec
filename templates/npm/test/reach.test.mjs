import assert from 'node:assert/strict';
import test from 'node:test';
import {applyReach, lawReach, reachText} from '../native-evidence.mjs';

const guarded = {
  law: 'example.vacuity::law::accepted',
  label: 'example.vacuity::an accepted offer',
  reach: {
    guards: 1,
    measured: true,
    advice: [{rule: 'adapter-guard', input: 'offer', message: 'Consider a harness strategy.'}],
  },
};
const plain = {law: 'example.vacuity::law::plain', label: 'example.vacuity::plain'};

test('reach sums each guard over the files a law wrote', () =>
{
  const reach = lawReach(guarded, [
    {law: guarded.label, reach: [{evaluated: 100, held: 40}, {evaluated: 40, held: 3}]},
    {law: guarded.label, reach: [{evaluated: 6, held: 2}, {evaluated: 2, held: 0}]},
    {law: plain.label, reach: [{evaluated: 9, held: 9}]},
    {law: guarded.label, outcome: 'passed'},
  ]);
  assert.deepEqual(reach, {
    status: 'measured',
    cases: 106,
    reached: 3,
    sites: [{evaluated: 106, held: 42}, {evaluated: 42, held: 3}],
  });
});

test('a guarded law without counts is unknown, and an unguarded one has no reach', () =>
{
  assert.equal(lawReach(guarded, []).status, 'unknown');
  assert.match(
    lawReach({...guarded, reach: {...guarded.reach, measured: false}}, []).reason,
    /does not count/,
  );
  assert.equal(lawReach(plain, []), undefined);
});

test('a passed law no generated case reached becomes vacuous', () =>
{
  const attempts = {
    [guarded.law]: {outcome: 'passed'},
    [plain.law]: {outcome: 'passed'},
  };
  const vacuous = applyReach(attempts, [guarded, plain], [
    {law: guarded.label, reach: [{evaluated: 105, held: 0}]},
  ]);
  assert.deepEqual(vacuous, [guarded]);
  assert.equal(attempts[guarded.law].outcome, 'vacuous');
  assert.equal(attempts[plain.law].outcome, 'passed');
  assert.deepEqual(reachText(guarded, attempts[guarded.law]), [
    '  example.vacuity::an accepted offer: 0 of 105 generated cases reached the consequence — VACUOUS',
    '    Consider a harness strategy.',
  ]);
  assert.deepEqual(reachText(plain, attempts[plain.law]), []);
});

test('reached, failed and unmeasured laws keep their outcome', () =>
{
  const attempts = {[guarded.law]: {outcome: 'passed'}};
  assert.deepEqual(
    applyReach(attempts, [guarded], [{law: guarded.label, reach: [{evaluated: 105, held: 7}]}]),
    [],
  );
  assert.equal(attempts[guarded.law].outcome, 'passed');
  assert.deepEqual(reachText(guarded, attempts[guarded.law]), [
    '  example.vacuity::an accepted offer: 7 of 105 generated cases reached the consequence',
  ]);
  const failed = {[guarded.law]: {outcome: 'failed'}};
  applyReach(failed, [guarded], [{law: guarded.label, reach: [{evaluated: 3, held: 0}]}]);
  assert.equal(failed[guarded.law].outcome, 'failed');
  const unknown = {[guarded.law]: {outcome: 'passed'}};
  assert.deepEqual(applyReach(unknown, [guarded], []), []);
  assert.equal(unknown[guarded.law].outcome, 'passed');
  assert.match(reachText(guarded, unknown[guarded.law])[0], /reach unknown/);
  // No case ran at all: nothing was measured to be vacuous.
  const none = {[guarded.law]: {outcome: 'passed'}};
  assert.deepEqual(applyReach(none, [guarded], [{law: guarded.label, reach: [{evaluated: 0, held: 0}]}]), []);
});

// fast-check's filter never gives up, so a refinement no random value meets
// made a generated property test run forever. The runtime's accepting is the
// filter's predicate and stops it.
test('a refinement filter gives up after its attempts', async () =>
{
  const {accepting} = await import('../../runtime/lawspec_runtime.mjs');
  const never = accepting(3, () => false);
  assert.equal(never(1), false);
  assert.equal(never(2), false);
  assert.throws(() => never(3), /refinement-generation-exhausted after 3 attempts/);
  // An accepted value starts the count again.
  const even = accepting(2, value => value % 2 === 0);
  for (const value of [1, 2, 3, 4, 5, 6]) assert.equal(even(value), value % 2 === 0);
});
