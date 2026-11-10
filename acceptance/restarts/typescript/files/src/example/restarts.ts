// User-owned LawSpec adapter: a tab's handlers, run inside an actor.
import * as data from '.././lawspec_data.js';
import {BarSupervisor} from '../lawspec_actors.js';

export function openTab(value0: unknown): data.Tab {
  return new data.Tab(0n);
}

export function add(value0: data.Tab, value1: number): data.Pair<bigint, data.Tab> {
  const after = value0.total + BigInt(value1);
  return new data.Pair(after, new data.Tab(after));
}

export function total(value0: data.Tab): data.Pair<bigint, data.Tab> {
  return new data.Pair(value0.total, value0);
}

// keepsTotal starts the bar, adds to the tab, crashes the tab, and reads its
// total through the same handle: the supervisor restarted it with the total
// it had.
export function keepsTotal(value0: number): bigint {
  const bar = BarSupervisor.start();
  bar.tab.addNow(value0);
  bar.tab.crashNow();
  const total = bar.tab.totalNow();
  bar.stop();
  return total;
}
