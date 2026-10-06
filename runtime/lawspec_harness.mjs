// The harness plane at run time (see docs/reference/language/harness.md):
// how a law's tests run, never what the law means. Generated tests call it
// for strategies' refinement checks, adequacy (cover, classify,
// label), run metadata (skip, known failing, timeout, repeat, retry flaky,
// order random) and benchmarks.
//
// Statistics go to standard output, and, when LAWSPEC_STATS names a
// directory, to one JSON file per test there, which lawspec test reads.
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

export class HarnessError extends Error {}

function record(name, entry) {
  const directory = globalThis.process?.env?.LAWSPEC_STATS;
  if (!directory) return;
  mkdirSync(directory, { recursive: true });
  const safe = name.replace(/[^A-Za-z0-9_-]/g, '_');
  writeFileSync(join(directory, `${safe}.json`), JSON.stringify(entry));
}

// Strategies are composed into fast-check arbitraries by the generated test.
// A drawn value must satisfy its input's refinements: a strategy may only
// produce values the law is about.
export function checkDrawn(strategy, name, holds, value) {
  if (!holds(value))
    throw new HarnessError(`the strategy ${strategy} produced ${show(value)} for ${name}, ` +
      "which is outside the input's refinement; a strategy may only produce values of its type");
  return value;
}

const show = (value) => {
  try { return JSON.stringify(value, (_, v) => typeof v === 'bigint' ? v.toString() : v) ?? String(value); }
  catch { return String(value); }
};

// Adequacy: what the generated cases covered.
const cases = new Map();
const best = new Map();

export function observe(law, { covers = [], classes = [], labels = [] } = {}) {
  const stats = cases.get(law) ?? { cases: 0, cover: {}, classes: {}, labels: {} };
  cases.set(law, stats);
  stats.cases += 1;
  for (const [label, holds] of covers) stats.cover[label] = (stats.cover[label] ?? 0) + (holds ? 1 : 0);
  for (const [label, holds] of classes) if (holds) stats.classes[label] = (stats.classes[label] ?? 0) + 1;
  for (const value of labels) stats.labels[String(value)] = (stats.labels[String(value)] ?? 0) + 1;
}

// target maximize: fast-check has no targeted search, so the best score is
// reported with the law's statistics.
export function target(score, law) {
  const value = Number(score);
  if (!best.has(law) || value > best.get(law)) best.set(law, value);
}

function adequacy(law, covers) {
  const stats = cases.get(law) ?? { cases: 0, cover: {}, classes: {}, labels: {} };
  cases.delete(law);
  const n = stats.cases;
  const results = covers.map(([percent, label]) => {
    const observed = n ? Math.round(10000 * (stats.cover[label] ?? 0) / n) / 100 : 0;
    return { label, required: percent, observed, met: n > 0 && observed >= percent };
  });
  const report = { law, cases: n, cover: results, classes: stats.classes, labels: stats.labels,
    ...(best.has(law) ? { best: best.get(law) } : {}) };
  best.delete(law);
  const lines = [`${law}: ${n} generated case(s)`];
  for (const r of results) lines.push(`  cover ${r.required}% "${r.label}": ${r.observed}%${r.met ? '' : ' (not met)'}`);
  for (const [label, count] of Object.entries(stats.classes)) lines.push(`  ${label}: ${(100 * count / (n || 1)).toFixed(1)}%`);
  for (const [label, count] of Object.entries(stats.labels)) lines.push(`  label ${label}: ${(100 * count / (n || 1)).toFixed(1)}%`);
  if (report.best !== undefined) lines.push(`  best target score: ${report.best}`);
  if (lines.length > 1) console.log(lines.join('\n'));
  return report;
}

async function withTimeout(test, milliseconds, law) {
  if (milliseconds === undefined) return test();
  let timer;
  const timeout = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new HarnessError(`${law} took longer than its timeout of ${milliseconds} ms`)), milliseconds);
  });
  try { return await Promise.race([Promise.resolve().then(test), timeout]); }
  finally { clearTimeout(timer); }
}

// Run one generated test of a law under its harness settings.
export async function run(law, name, test, { timeout, repeat = 1, retries = 0, covers = [], observed = false } = {}) {
  let attempts = 0;
  let flaky = false;
  let report = null;
  for (;;) {
    attempts += 1;
    try {
      for (let i = 0; i < repeat; i++) {
        cases.delete(law);
        await withTimeout(test, timeout, law);
        report = observed ? adequacy(law, covers) : null;
        const unmet = report ? report.cover.filter((r) => !r.met) : [];
        if (unmet.length) {
          record(name, { ...report, test: name, outcome: 'failed' });
          throw new HarnessError(unmet.map((r) =>
            `${law}: cover ${r.required}% "${r.label}" was not met (${r.observed}% of ${report.cases} generated cases)`).join('; '));
        }
      }
      break;
    } catch (error) {
      if (error instanceof HarnessError || attempts > retries) {
        if (!(error instanceof HarnessError)) record(name, { law, test: name, outcome: 'failed', attempts });
        throw error;
      }
      flaky = true;
    }
  }
  record(name, { law, test: name, outcome: flaky ? 'flaky' : 'passed', attempts, ...(report ?? {}) });
  if (flaky) console.warn(`${law} is flaky: it failed, then passed on attempt ${attempts}`);
}

export function skip(law, reason) {
  record(law, { law, outcome: 'skipped', reason });
}

// A known-failing law's tests must fail. One that passes is reported: the
// harness should no longer say it is known to fail.
export async function knownFailing(law, name, reason, tests) {
  for (const test of tests) {
    try { await test(); }
    catch (error) {
      record(name, { law, test: name, outcome: 'known-failing', reason });
      console.log(`${law} is known to fail (${reason}): ${error?.message?.split('\n')[0] ?? error}`);
      return;
    }
  }
  record(name, { law, test: name, outcome: 'known-failing-passed', reason });
  throw new HarnessError(`${law} is marked known failing (${reason}), but it passes; remove \`known failing\` from its harness`);
}

// order random: the tests in an order chosen by the run's seed
// (LAWSPEC_SEED, or one chosen here), printed so the order can be replayed.
export function shuffled(items, unit = 'the unit') {
  const given = globalThis.process?.env?.LAWSPEC_SEED;
  const seed = given === undefined ? Math.floor(Math.random() * 2 ** 31) : Number(given) | 0;
  console.log(`order random seed ${seed} (${unit}): LAWSPEC_SEED=${seed} replays this order`);
  let state = seed;
  const next = () => {
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  const result = [...items];
  for (let i = result.length - 1; i > 0; i--) {
    const j = Math.floor(next() * (i + 1));
    [result[i], result[j]] = [result[j], result[i]];
  }
  return result;
}

// parallel: how the unit's tests ran at the same time. node:test runs them
// concurrently in one process: async laws overlap, synchronous ones take
// turns on the event loop.
export function parallelism(unit) {
  const workers = globalThis.navigator?.hardwareConcurrency ?? 1;
  const mode = 'in-process concurrency (async laws overlap; synchronous laws take turns)';
  record(`parallel ${unit}`, { parallel: unit, mode, workers });
  console.log(`${unit} runs in parallel: ${mode}`);
}

// Measured, never asserted: the mean and fastest time of body.
export async function benchmark(name, body, budget = 200, limit = 100000) {
  const times = [];
  const started = performance.now();
  while (times.length < limit && (performance.now() - started < budget || times.length < 3)) {
    const before = performance.now();
    await body();
    times.push(performance.now() - before);
  }
  const mean = times.reduce((a, b) => a + b, 0) / times.length;
  const fastest = Math.min(...times);
  console.log(`benchmark ${name}: ${times.length} iteration(s), mean ${(mean * 1000).toFixed(2)} us, fastest ${(fastest * 1000).toFixed(2)} us`);
  record(`benchmark ${name}`, { benchmark: name, iterations: times.length, mean_ns: Math.round(mean * 1e6), min_ns: Math.round(fastest * 1e6) });
}
