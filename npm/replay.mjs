// Generated from templates/npm/replay.mjs by lawspec-dev generate. Do not edit.
// Batch planning and failure-database recording for `lawspec test`.
//
// A law whose own tests failed is kept in the failure database with the seed
// that exposed it, and the next run replays it with that seed before the
// other laws run with a fresh one. Everything here is pure: each function
// reads only its arguments and returns new values. The CLI reads and writes
// the files and starts the native tools.

// The mark on a database entry written by the current rule: the law's own
// tests failed with the entry's seed. Before LawSpec 0.34 a failing native
// invocation recorded every law it ran, passing or not, with no mark. An
// unmarked entry is therefore unverified: it gets one replay with its seed
// and is then either marked (its own tests failed) or removed.
export const ownFailure = 'own-tests-failed';

export const verified = entry => entry?.cause === ownFailure;

function replaySeed(law, entry)
{
  const text = String(entry?.seed);
  if (!/^[0-9]+$/.test(text))
    throw new Error(
      `The failure database holds no whole-number seed for ${law}`,
    );
  return text;
}

// The batches of one run, in order: one replay batch per recorded seed, in
// the order the seeds first appear, then every other law with the fresh
// seed. `replay: false` (an explicit --seed) runs every law with that seed.
export function planBatches(stale, database, {seed, replay = true})
{
  const replayed = replay ? stale.filter(entry => database[entry.law]) : [];
  const seeds = replayed.map(entry =>
    replaySeed(entry.law, database[entry.law]),
  );
  return [
    ...[...new Set(seeds)].map(recorded => ({
      seed: recorded,
      replay: true,
      entries: replayed.filter((_, index) => seeds[index] === recorded),
    })),
    {
      seed: String(seed),
      replay: false,
      entries: stale.filter(entry => !replayed.includes(entry)),
    },
  ].filter(batch => batch.entries.length);
}

// What one batch has shown so far.
export const startBatch = () => ({failed: false, executed: 0});

// One native invocation of a batch has ended. `tests` is every test its
// report shows; `lawTests` counts those that belong to a law of the batch.
// A failed invocation in which no law's test executed could not start (a
// missing tool, a build that does not compile, a test file that does not
// load and is reported as one failed test of its own), so the rest of its
// batch would fail the same way and is not started.
export function afterInvocation(progress, {ok, tests, lawTests})
{
  const failed = !ok || tests.some(test => test.status === 'failed');
  return {
    failed: progress.failed || failed,
    executed: progress.executed + lawTests,
    invocationFailed: failed,
    continueBatch: !failed || lawTests > 0,
  };
}

// A failed batch does not stop the later ones: its failing laws are its own.
// Only a failed batch in which no law's test executed at all stops the run.
export const continueRun = progress =>
  !progress.failed || progress.executed > 0;

// The failure database after a run. `attempts` holds this run's attempt for
// each law in `stale`; `passed` holds the laws recorded as passing.
// - A law that passed leaves.
// - A law whose own tests failed is recorded with the seed it ran with.
// - An unverified entry whose law executed tests without failing leaves: it
//   has had its replay and did not fail on its own.
// - Anything else is kept: a verified failure whose law did not complete
//   this time, and any entry whose law did not execute.
export function recordFailures(database, stale, {passed, attempts, at})
{
  const next = {...database};
  for (const entry of stale)
  {
    const attempt = attempts[entry.law];
    if (passed.has(entry.law)) delete next[entry.law];
    else if (attempt?.outcome === 'failed')
      next[entry.law] = {seed: attempt.seed, failed: at, cause: ownFailure};
    else if (
      next[entry.law] &&
      !verified(next[entry.law]) &&
      attempt?.tests?.length
    )
      delete next[entry.law];
  }
  return next;
}

// What each batch did, for the summary: the seed it used, the laws it ran
// and the laws no native process was started for.
export function batchSummaries(batches, attempts)
{
  return batches.map(batch =>
  {
    const unstarted = batch.entries
      .filter(entry => attempts[entry.law]?.outcome === 'not-run')
      .map(entry => entry.law);
    return {
      seed: batch.seed,
      replay: batch.replay,
      ran: batch.entries
        .map(entry => entry.law)
        .filter(law => !unstarted.includes(law)),
      ...(unstarted.length ? {notRun: unstarted} : {}),
    };
  });
}

// "ran 3 law(s) with seed 7", or each batch's own seed when there are several.
export function ranText(summaries)
{
  const active = summaries.filter(batch => batch.ran.length);
  const total = active.reduce((sum, batch) => sum + batch.ran.length, 0);
  if (active.length <= 1)
    return `ran ${total} law(s)${active.length ? ` with seed ${active[0].seed}` : ''}`;
  return (
    `ran ${total} law(s): ` +
    active
      .map(
        batch =>
          `${batch.ran.length} ${batch.replay ? 'replayed ' : ''}with seed ${batch.seed}`,
      )
      .join(', ')
  );
}
