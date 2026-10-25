import type {NativeOutcome, NativeExecutionAttempt, RecordedNativeExecutionAttempt, NativeExecutionObservation} from '../../npm/index.js';

declare const fresh: NativeExecutionAttempt;
const current: NativeOutcome = fresh.outcome;
const archived: RecordedNativeExecutionAttempt = {...fresh, outcome: 'known-failing'};
const observation: NativeExecutionObservation = {
  target: 'javascript', root: '/bank', outcome: 'known-discrepancy', freshness: 'stale',
  reason: 'The recorded compiler differs', attempt: archived,
};
const displayed: NativeOutcome = observation.outcome;

// @ts-expect-error An archived spelling is not a newly produced outcome.
const invalid: NativeOutcome = 'known-failing';
// @ts-expect-error A recorded attempt is not necessarily a newly produced attempt.
const invalidAttempt: NativeExecutionAttempt = archived;

export {current, displayed, invalid, invalidAttempt};
