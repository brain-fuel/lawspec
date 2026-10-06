// User-owned LawSpec adapter: nap notes when it starts and ends a sleep.
import { appendFileSync } from 'node:fs';

function note(event, n) {
  const path = globalThis.process?.env?.LAWSPEC_SCHEDULE_LOG;
  if (path) appendFileSync(path, `${event} ${n} ${(performance.timeOrigin + performance.now()).toFixed(3)}\n`);
}

export async function nap(value0) {
  note('start', value0);
  await new Promise((resolve) => setTimeout(resolve, 300));
  note('end', value0);
  return true;
}
