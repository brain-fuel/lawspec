// User-owned LawSpec adapter: the workflow runtime under test.
import * as ls from '../lawspec_runtime.js';

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
