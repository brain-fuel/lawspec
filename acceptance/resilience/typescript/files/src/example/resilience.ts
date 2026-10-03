// User-owned LawSpec adapter: the workflow runtime under test.
import * as ls from '../lawspec_runtime.js';
import * as data from '../lawspec_data.js';
import * as workflows from '../lawspec_definitions/example/limits.js';
import * as quotes from './limits.js';

export function runtimeExponentialDelay(value0: bigint, value1: bigint, value2: bigint): bigint {
  return ls.retryDelay(['exponential', value0, value1, null], value2);
}

export function runtimeLinearDelay(value0: bigint, value1: bigint, value2: bigint): bigint {
  return ls.retryDelay(['linear', value0, value1], value2);
}

export function runtimeFibonacciDelay(value0: bigint, value1: bigint): bigint {
  return ls.retryDelay(['fibonacci', value0], value1);
}

export function splitMix(value0: bigint, value1: number): Array<bigint> {
  const random = new ls.SplitMix64(value0);
  return Array.from({length: value1}, () => random.next());
}

export function fullJitter(value0: bigint, value1: bigint): bigint {
  return ls.jittered('full', value1, 0n, 0n, new ls.SplitMix64(value0));
}

function waits(attempts: number, when: ((error: unknown) => boolean) | null): Array<bigint> {
  const runtime = new ls.WorkflowRuntime(new ls.VirtualClock());
  const retry = {strategy: ['exponential', 100000n, 2n, null], attempts: BigInt(attempts), jitter: 'none', when};
  ls.runStage(runtime.context(), {stage: 'stage', retry, timeout: null},
      () => new ls.DataValue('Either::Left', [0n]));
  return runtime.trace.filter((event: any) => event[0] === 'sleep').map((event: any) => event[2]);
}

export function retriedWaits(value0: number): Array<bigint> {
  return waits(value0, null);
}

export function rejectedWaits(value0: number): Array<bigint> {
  return waits(value0, () => false);
}


/** Calls the generated workflow at each time under one runtime. */
export function limitedAt(value0: Array<bigint>): Array<boolean> {
  const clock = new ls.VirtualClock();
  const runtime = new ls.WorkflowRuntime(clock);
  return value0.map(time => {
    clock.time = time;
    return workflows.limited(runtime.context(), new data.Ticket(0n)) instanceof data.Right;
  });
}

/** Books a ticket under a fresh runtime: the stages whose undos ran. */
export function compensationsFor(value0: bigint): Array<string> {
  const runtime = new ls.WorkflowRuntime(new ls.VirtualClock());
  workflows.book(runtime.context(), new data.Ticket(value0));
  return runtime.trace.filter((event: any) => event[0] === 'compensate').map((event: any) => event[1]);
}

/** Quotes a ticket under a runtime with the real clock: whether it timed out. */
export async function quoteTimedOut(value0: bigint): Promise<boolean> {
  const runtime = new ls.WorkflowRuntime(new ls.RealClock());
  const result = await workflows.quoted(runtime.context(), new data.Ticket(value0));
  return result instanceof data.Left && result.value instanceof data.QuotedErrorQuotedTimedOut;
}

/** Quotes a ticket under a runtime with the real clock: whether it succeeded within 400ms, for ticket -2 through a hedged attempt. */
export async function quoteHedged(value0: bigint): Promise<boolean> {
  quotes.resetQuotes();
  const runtime = new ls.WorkflowRuntime(new ls.RealClock());
  const started = performance.now();
  const result = await workflows.hedged(runtime.context(), new data.Ticket(value0));
  const quick = performance.now() - started < 400;
  const hedged = runtime.trace.some((event: any) => event[0] === 'hedge');
  return result instanceof data.Right && quick && (value0 !== -2n || hedged);
}
