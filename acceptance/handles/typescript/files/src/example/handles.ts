// User-owned LawSpec adapter: Jobs is a plain array used as a queue.
// JavaScript runs one call at a time, so the array needs no lock.
import * as data from '.././lawspec_data.js';

export function newJobs(value0: unknown): unknown {
  return [] as number[];
}

export function submit(value0: unknown, value1: number): void {
  (value0 as number[]).push(value1);
}

export function take(value0: unknown): data.Maybe<number> {
  const jobs = value0 as number[];
  return jobs.length === 0 ? new data.Nothing<number>() : new data.Just<number>(jobs.shift()!);
}

export function pending(value0: unknown): number {
  return (value0 as number[]).length;
}
