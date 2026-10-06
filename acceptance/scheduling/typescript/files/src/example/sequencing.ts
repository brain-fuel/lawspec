// User-owned LawSpec adapter: pause notes when it is called.
import { appendFileSync } from 'node:fs';

function note(event: string, n: number): void {
  const path = globalThis.process?.env?.LAWSPEC_SCHEDULE_LOG;
  if (path) appendFileSync(path, `${event} ${n} ${(performance.timeOrigin + performance.now()).toFixed(3)}\n`);
}

export function pause(value0: number): boolean {
  note('start', value0);
  const until = Date.now() + 5;
  while (Date.now() < until) { /* a short pause */ }
  note('end', value0);
  return true;
}
